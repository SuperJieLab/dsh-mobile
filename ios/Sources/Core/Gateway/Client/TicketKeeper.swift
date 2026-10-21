import Foundation

/**
 * 访问票的生命周期：手上有没有、还剩多久、要不要去换、并发时谁去换。
 *
 * **它换不换得成，取决于一个注入进来的动作**（`renew`）—— 本类不认识线路、不认识协议、
 * 不认识设备凭证从哪来。这不是为了少写几行，是依赖方向：`Core/Secrets/` 是下层（它只管
 * 设备凭证那个落盘资产），而换票必须走网关的网络与协议；把票的维护放进 `Secrets/` 会让
 * 下层认识 `Gateway`，`LayeringTests` 里那张 `coreUpwardBans` 表禁的正是这件事。
 * ⇒ 票的维护归 `Gateway/Client/`，`Secrets/` 只留下「设备凭证存在哪」。
 *
 * 两者都叫「凭证」，但形状不同：设备凭证是**资产**（落盘、要保护、活过重启），访问票是
 * **运行时产物**（纯内存、15 分钟、可重算）。可重算的东西不该进资产目录。
 *
 * 本类的三个职责：
 * 1. **过期判定只有这一处** —— 全仓唯一的 `expiresAt` 比较在这里。
 * 2. **单飞**：同一时刻只允许一次换票在途，并发的调用搭同一趟；否则进屏那一拍 HTTP 与 WS
 *    会各发一次 `refresh`。
 * 3. **三态**：拿不到时区分「不会自己好」与「等一等就好」（见 `AccessTicket`）。
 *
 * **重试不在这里。** 隔多久再试是各使用方自己的事：WS 有退避曲线，HTTP 有它自己的失败面。
 * 本类若自带一套重试，两者会嵌套，实际间隔成了乘积，而界面上的「重连中…」该显示哪个延时
 * 没人算得清。
 */
@MainActor
final class TicketKeeper {

    /// 换票换到的全部东西 —— 票本身与它的到期时刻。
    ///
    /// 为什么不复用 `AccessTicket`：那个三态是**给使用方看的**，使用方只需要一个字符串；
    /// 而到期时刻只有本类关心。让 `granted` 背上一个使用方永远不读的字段，等于把本类的
    /// 内部状态泄漏进公开形状。
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

    /// 换票：拿设备凭证去换一张。由网关门面提供 —— 它才知道线路与协议。
    ///
    /// 返回 `Renewal` 而不是抛错：`GatewayClientError` 里的那些词汇（怎么读 401、什么算传输
    /// 失败）属于那一层，本类不该认识。
    private let renew: (String) async -> Renewal

    private var issued: Issued?
    /// 在途的那一趟 —— 并发的调用者等它，不另发一次。
    private var inFlight: Task<Renewal, Never>?

    init(renew: @escaping (String) async -> Renewal) {
        self.renew = renew
    }

    /// 还活着的票；没有就是 `nil`。**过期的票等价于没有票** —— 这是全仓唯一的过期判定。
    ///
    /// 留给「只有同步上下文可用」的调用方（WebSocket 的 upgrade 请求）。它只回答现状，
    /// 不会去换；要换走 `ticket`。
    func validToken(now: Date = Date()) -> String? {
        guard let issued, now < issued.expiresAt else { return nil }
        return issued.token
    }

    /// 要一张票：有就立刻给，没有就去换（并发的调用共享同一趟）。
    ///
    /// - Parameter deviceToken: 设备凭证。缺席即未配对 —— `.unavailable`，一次网络都不发。
    func ticket(deviceToken: String?) async -> AccessTicket {
        if let existing = validToken() { return .granted(existing) }
        return await renewAnyway(deviceToken: deviceToken)
    }

    /// **换一张新的，不问手上有没有。**
    ///
    /// 用于「服务端刚刚说了 401」之后：本地认为手里那张还没到期，而服务端不认它（Mac 重启
    /// 会清空那边的活跃票表、票也可能被批量作废）。此时读缓存只会把同一枚死票再发一遍。
    /// 本方法**不清**旧票 —— 换到新票时才覆盖；换不到时旧票留着也没用，`validToken` 会因
    /// 过期自灭，但更常见的是它本来就没到期，于是下一次 `ticket()` 又会把它递出去。
    /// 所以换不到时这里主动 `clear()`：一枚被服务端否认过的票不该继续被当成有效。
    func renewAnyway(deviceToken: String?) async -> AccessTicket {
        // 有人正在换：搭那一趟 —— 那就是"一张新票"的全部意义。各自拿着「没有」回去重问，
        // 是单飞要消掉的那种重试。
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
        // 暂时换不到：手里那张仍可能有效（也可能正是刚被 401 的那张）。留给下一个 401 处理，
        // 这里不擅自清 —— 清掉会让「网络抖一下就丢票」变成常态。
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
