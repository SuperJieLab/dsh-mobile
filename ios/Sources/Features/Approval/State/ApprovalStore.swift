/**
 * 待批审批的宿主：持门面，把判定的输出镜像成可观察属性，并把一次应答的三种结局翻成卡片状态。
 *
 * 判定在 `ApprovalInbox`（纯值类型，不认识客户端）。这里只剩三件事：
 * 1) 把 `rebuild` / `receive` 转给判定，再把结果发布出去；
 * 2) 把「去答一个」发出去（幂等判重 + 可应答性检查）；
 * 3) 按结局改卡集合与状态 —— 成功与 `unknown-approval` 都撤卡（后者带说明），传输失败只标
 * 「已发出，结果未知」：断线的写操作是「未知」不是「失败」。
 *
 * 每次都带客户端生成的 `answerId`（幂等键）：回包丢了重试，服务端回放第一次的结果，
 * 绝不二次投递。
 *
 * 消费者：`SessionSync`（持它，订阅 `objectWillChange` 把刷新冒泡给视图）、`SessionDetailView`
 * （读 `pending` / `states` / `notice`，调 `answer`）、`ApprovalCard`（读 `AnswerState` 类型）。
 */
import Combine
import Foundation

@MainActor
final class ApprovalStore: ObservableObject {

    /// 一张卡片的应答进展（不在 `pending` 里就没有这一项）。
    enum AnswerState: Equatable {
        /// 还没动过。
        case idle
        /// 已发出，回包还没到 —— 结果未知。
        case unknown
    }

    @Published private(set) var pending: [ApprovalInbox.PendingApproval] = []
    /// 每条审批的应答进展（不在 `pending` 里的不存在）。
    @Published private(set) var states: [String: AnswerState] = [:]
    /// 与单条卡片无关的一句话说明（如「审批已被取消」）。
    @Published private(set) var notice: String?

    private let client: GatewayClient
    /// 判定。宿主持有它、把结果发布出去 —— 本类型不重算任何规则。
    private var inbox = ApprovalInbox()

    init(client: GatewayClient) {
        self.client = client
    }

    /// 用镜像里的全部事件重建待批集合。
    func rebuild(from events: [SessionEvent]) {
        inbox.rebuild(from: events)
        pending = inbox.pending
        pruneStates()
    }

    /// 网关审批推送：交给判定吸收，再把卡集合发布出去。
    ///
    /// 清状态行的时机照旧：`cancel` 只清「按 `eventId` 记的那一行」（独立帧卡的那一行）；
    /// 审计卡的行留到下一次重算，由 `pruneStates` 过滤 —— 那时卡已经不在集合里了。
    /// `sync` 之后才做整体过滤；`request` 不清理。
    func receive(_ payload: JSONValue) {
        inbox.absorb(payload)
        pending = inbox.pending
        switch payload["kind"]?.string {
        case "cancel":
            if let eventId = payload["eventId"]?.string { states[eventId] = nil }
        case "sync":
            pruneStates()
        default:
            break
        }
    }

    /// 不能应答时给用户的一句话。卡上显示它、应答的兜底也读它 —— 同一件事只写一处。
    static let notForwardedNote = "这条审批还没有经由网关转发到手机 —— "
        + "请在 Mac 上处理，或稍候重进会话。"

    /// 应答一条待批审批。寻址键 = 绑定到的 waterfall `eventId`；还没绑上的卡片
    /// （重建出的、转发帧未到）不能应答 —— 而不是把审计 id 冒充线上键。
    func answer(_ approval: ApprovalInbox.PendingApproval, allow: Bool) async {
        guard states[approval.id] == nil || states[approval.id] == .idle else { return }
        // `canAnswer` 是卡与宿主共用的唯一规则；这里仍留守卫，兜住「渲染后、点击前」帧被撤的竞态。
        guard approval.canAnswer, let eventId = approval.eventId else {
            notice = Self.notForwardedNote
            return
        }
        do {
            try await client.answerApproval(eventId: eventId, allow: allow, answerId: UUID().uuidString)
            // 自清（上游行为：receiveRemoteEventResult 先移除应答者自己的 delivery 再广播
            // cancel —— 自己答掉的审批，cancel 只发给别人，我们收不到收口帧）。上游语义
            // 「先答先收口」，回包成功即结局已定，与 Web UI 同样在应答当下收掉卡片。
            drop(approval)
            notice = "已投递：\(allow ? "允许" : "拒绝")"
        } catch GatewayClientError.refused(let failure)
            where failure.code == GatewayErrorCode.unknownApproval.rawValue {
            // 审批已不在：撤卡。真正的结局以 decided 为准，未回流时重开会话重建时可见。
            notice = failure.readableDescription
            drop(approval)
        } catch {
            // 传输失败 ≠ 未生效：如实转「未知」，等 decided 收口。
            states[approval.id] = .unknown
        }
    }

    /// 撤一张卡并清掉它的状态行 —— 两个「结局已定」的分支走这里。
    private func drop(_ approval: ApprovalInbox.PendingApproval) {
        inbox.remove(id: approval.id)
        pending = inbox.pending
        states[approval.id] = nil
    }

    /// 清掉已不在屏上的状态行（免得字典里积着看不见的旧值）。
    private func pruneStates() {
        states = states.filter { key, _ in
            pending.contains(where: { card in card.id == key || card.eventId == key })
        }
    }
}
