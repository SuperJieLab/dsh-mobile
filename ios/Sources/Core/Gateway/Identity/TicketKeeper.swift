/**
 * 访问票：手上有没有、还剩多久、要不要去换、并发时谁去换。
 *
 * 换票靠注入的 `renew`：本类不认识线路、协议与设备凭证。三个职责：过期判定只此一处、
 * 单飞（并发搭同一趟）、三态。**重试不在这里** —— 隔多久再试归使用方，自带一套会与
 * WS 退避、HTTP 失败面嵌套成乘积。
 */
import Foundation

/**
 * 一次「要一张访问票」的结果 —— 本文件唯一对外交出的形状。
 * **三态，不是两态**：`.granted` 用它；`.unavailable` 没有用户动作就不会变 ⇒ **停**；
 */
enum AccessTicket: Equatable {
    /// 一张还活着的票。
    case granted(String)
    /// 拿不到，且**不会自己好** —— 需要用户去配对，或解释关系已被撤销。
    case unavailable
    /// 这次拿不到，但状态没有坏 —— 等一会儿再来。
    case retryLater

    /// 手上的票本身（只有 `.granted` 才有）。
    var token: String? {
        guard case .granted(let token) = self else { return nil }
        return token
    }
}

@MainActor
final class TicketKeeper {

    /// 换票换到的全部东西 —— 票本身与它的到期时刻。
    struct Issued: Equatable {
        let token: String
        let expiresAt: Date
    }

    /// 换票的结果：换到了带票与到期时刻，没换到要区分两种缘由。
    enum Renewal: Equatable {
        case issued(Issued)
        /// 不会自己好（未配对 / 关系被撤销）。
        case unavailable
        /// 这一次没成，状态没坏。
        case retryLater
    }

    /// 换票：拿设备凭证去换一张，由网关门面提供 —— 它才知道线路与协议。
    /// 返回 `Renewal` 而不是抛错：`RpcClientError` 的词汇属于那一层。
    private let renew: (String) async -> Renewal

    private var issued: Issued?
    /// 在途的那一趟 —— 并发的调用者等它，不另发一次。
    private var inFlight: Task<Renewal, Never>?

    init(renew: @escaping (String) async -> Renewal) {
        self.renew = renew
    }

    /// 还活着的票；没有就是 `nil`。**过期的票等价于没有票** —— 全仓唯一的过期判定。
    /// 留给只有同步上下文的调用方（WebSocket 的 upgrade）；它只回答现状，要换走 `ticket`。
    func validToken(now: Date = Date()) -> String? {
        guard let issued, now < issued.expiresAt else { return nil }
        return issued.token
    }

    /// 要一张票：有就立刻给，没有就去换（并发的调用共享同一趟）。
    /// - Parameter deviceToken: 缺席即未配对 —— `.unavailable`，一次网络都不发。
    func ticket(deviceToken: String?) async -> AccessTicket {
        if let existing = validToken() { return .granted(existing) }
        return await renewAnyway(deviceToken: deviceToken)
    }

    /// **换一张新的，不问手上有没有。** 用于「服务端刚说了 401」之后：本地认为没过期而服务端不认。
    /// 读缓存只会把同一枚死票再发一遍。本方法**不清**旧票 —— 换到新票时才覆盖。
    func renewAnyway(deviceToken: String?) async -> AccessTicket {
        // 有人正在换：搭那一趟 —— 各自拿着「没有」回去重问，是单飞要消掉的那种重试。
        if let inFlight { return Self.answer(await inFlight.value) }
        guard let deviceToken else { return .unavailable }

        let task = Task<Renewal, Never> { [renew] in
            await renew(deviceToken)
        }
        inFlight = task
        let renewal = await task.value
        inFlight = nil
        // 换到的东西存在这里 —— 让「谁去换」与「换到的票存哪」是同一处，两个使用方都不必知道。
        switch renewal {
        case .issued(let fresh): issued = fresh
        // 服务端否认过的那张不能留着：留着的话下一次 `ticket()` 会把它当有效期内的票递出去。
        case .unavailable: clear()
        // 暂时换不到：手里那张仍可能有效，不擅自清 —— 清掉会让「网络抖一下就丢票」变成常态。
        case .retryLater: break
        }
        return Self.answer(renewal)
    }

    /// 清掉手上的票。关系被掐断时必须调 —— 否则下一个请求会拿着一枚已经无主的票出门。
    func clear() {
        issued = nil
    }

    /// 内部形状 → 使用方看的形状。两种没换到的缘由一一对应，不合并。
    private static func answer(_ renewal: Renewal) -> AccessTicket {
        switch renewal {
        case .issued(let fresh): return .granted(fresh.token)
        case .unavailable: return .unavailable
        case .retryLater: return .retryLater
        }
    }
}
