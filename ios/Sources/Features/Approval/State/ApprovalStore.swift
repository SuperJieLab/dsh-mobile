/**
 * 待答审批的宿主：持表、发布给界面、把一次应答的三种结局翻成卡片状态。
 *
 * 判定在 `ApprovalTable`，这里只剩三件事：把帧转给表并发布结果、把「去答一个」发出去
 * （在途守卫 + 幂等键）、按结局改状态与说明。它与 App 同寿 —— 停在会话列表时表照样在长。
 *
 * 每次应答都带客户端生成的 `answerId`：回包丢了重试，网关回放第一次的结果，绝不二次投递。
 */
import Combine
import Foundation

/// 发一次应答。收成一行是为了三种结局能被分别注入 —— 它们只在网络那一层分得开，
/// 而「卡留不留、说明什么」全按结局分支。
@MainActor
protocol ApprovalAnswering {
    func answer(eventId: String, allow: Bool, answerId: String) async throws
}

/// 生产实现：走既有的一次 HTTP 应答。
///
/// `ok` 只意味着**已投递**，权威结果以流里的 `approval/decided` 为准。失败如实上抛：
/// `unknown-approval` 表示这条审批已经不在了。
@MainActor
struct GatewayApprovalAnswerer: ApprovalAnswering {
    let client: RpcClient

    func answer(eventId: String, allow: Bool, answerId: String) async throws {
        let _: ApprovalAnswerResponse = try await client.perform(
            ApprovalAnswerRequest(
                eventId: eventId, decision: allow ? "allow" : "deny", answerId: answerId
            )
        )
    }
}

@MainActor
final class ApprovalStore: ObservableObject {

    /// 一张卡的应答进展。没有这一项 = 还没动过（也就可以按）。
    enum AnswerState: Equatable {
        /// 请求已发出、回包还没到。
        case sending
        /// 已发出但结果未知（传输失败）—— 卡留着，等上游结算。
        case unknown
        /// 服务端拒了这次投递，附人话说明 —— 那个问题仍挂在网关的暂存里。
        case refused(String)
    }

    /// 表本身发布出去：它一变，读它的视图就重算。不另存一份镜像 ——
    /// 两份数据会有「谁先更新」的问题，而这里没有第二个写者。
    @Published private var table = ApprovalTable()
    @Published private(set) var states: [String: AnswerState] = [:]
    /// 每个会话最近一句话（「已投递」「这条已经不在了」）。新卡到达即清 —— 说明讲的是上一件事。
    @Published private(set) var notices: [String: String] = [:]

    private let answerer: any ApprovalAnswering

    init(answerer: any ApprovalAnswering) {
        self.answerer = answerer
    }

    /// 某个会话还挂着的卡，按到达顺序。
    func pending(in sessionId: String) -> [ApprovalTable.Entry] {
        table.pending(in: sessionId)
    }

    func state(for identity: String) -> AnswerState? {
        states[identity]
    }

    func notice(for sessionId: String) -> String? {
        notices[sessionId]
    }

    /// 两处接线一次接完：待答调用的两条货物、源失效清空。
    ///
    /// 两处各自能单独坏，而且坏了都不编译失败 —— 症状分别是「审批永不显示」与
    /// 「网关的上游没了之后留着一张按不动的卡」。
    ///
    /// **每一条 `ready` 都清空**（不论代次值）：网关在 `ready` 之后紧跟着重放当前集合，
    /// 两者在同一个帧序列里相邻、客户端同步处理，界面上看不到中间态。这样表就没有跨代
    /// 状态 —— 与上游「句柄表是局部变量、代际更替随函数消失」同一个形态。
    func attach(events: EventStream) {
        events.onCargo("waterfall") { [weak self] payload in self?.receive(payload) }
        // 撤回的解释在这里：`eventId` 是唯一的寻址信息。没有它删不掉任何东西 —— 留着这张卡
        // 比误删别人的强。
        events.onCargo("cancel") { [weak self] payload in
            guard let eventId = payload["eventId"]?.string, !eventId.isEmpty else {
                Log.warn(Log.Module.session, "dropped a cancel without an eventId")
                return
            }
            self?.cancel(eventId: eventId)
        }
        events.onGeneration { [weak self] _ in self?.clear() }
    }

    /// 网关推来的一条待答调用。
    ///
    /// 载荷是上游 waterfall 的四个字段原样；卡上要显示的字段由表自己从 `request` 里取。
    func receive(_ payload: JSONValue) {
        table.absorb(payload)
        if let sessionId = payload["agentId"]?.string {
            // 新的一问来了，上一句说明（「已投递」/「已经不在了」）讲的是别的事。
            notices[sessionId] = nil
        }
        pruneStates()
    }

    /// 一条撤回：表里删掉它，它的应答状态一起清（状态字典里不该留看不见的旧值）。
    func cancel(eventId: String) {
        table.remove(eventId: eventId)
        states[eventId] = nil
    }

    /// 网关的上游没了：手里的项一条都答不了。之后由网关重投重建。
    func clear() {
        table.clear()
        states.removeAll()
        notices.removeAll()
    }

    /// 应答一张卡。守卫只看「有没有状态」—— 在途、未知、被拒的那一张都不再发第二次。
    func answer(_ entry: ApprovalTable.Entry, allow: Bool) async {
        guard states[entry.eventId] == nil else { return }
        // 发出之前就置位：写在回包之后的话，等待期间守卫是空的，连点两次会发两次。
        states[entry.eventId] = .sending
        // 收尾统一在这一处：三个出口都要清掉已不在表里的状态行，早退的那两个
        // 漏掉时，下一张同身份的卡会因为「已经有状态」而按不动。
        defer { pruneStates() }
        do {
            try await answerer.answer(
                eventId: entry.eventId, allow: allow, answerId: UUID().uuidString
            )
            // 上游先摘掉自己的投递再广播取消 —— 应答者收不到自己的收口帧，等就是永远等。
            settle(entry, notice: ApprovalStore.deliveredNote(allow: allow))
        } catch RpcClientError.refused(let failure)
            where failure.code == GatewayErrorCode.unknownApproval.rawValue {
            // 这条已经不在了：留着就是一张永远按不动的卡。
            settle(entry, notice: failure.readableDescription)
        } catch RpcClientError.refused(let failure) {
            // 服务端拒了这次投递，问题仍挂着 —— 卡留着并写明原因。
            states[entry.eventId] = .refused(failure.readableDescription)
        } catch {
            // 传输失败 ≠ 未生效：如实转「未知」，等上游结算。
            states[entry.eventId] = .unknown
        }
    }

    /// 结局已定：撤卡、写一句说明。
    ///
    /// 等待期间这一条可能已被上游的 `cancel` 撤掉（那时状态行也跟着清空了）——
    /// 卡都不在了，这句话就成了没有指代的一句，所以只在它仍是自己那一张时才写。
    private func settle(_ entry: ApprovalTable.Entry, notice: String) {
        table.remove(eventId: entry.eventId)
        guard states[entry.eventId] == .sending else { return }
        states[entry.eventId] = nil
        notices[entry.sessionId] = notice
    }

    /// 清掉已不在表里的状态行。
    private func pruneStates() {
        let live = Set(table.entries.map(\.eventId))
        states = states.filter { live.contains($0.key) }
    }
}
