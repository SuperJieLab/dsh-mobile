import Foundation

/// 待批审批的手机侧状态机（M5）。
///
/// 事实来源与会话内容同一条：**会话日志**。`approval/asked` 挂起一个问题，
/// `approval/decided`（无论谁答的、无论什么结局）收口它 —— 所以本类的重建
/// 就是「asked 减去 decided」，输入永远是镜像里的窗口事件，不自持一份真相。
///
/// 应答的三种下场，各自如实呈现（Plan §3.3 决定 3 —— 断线的写操作是
/// 「未知」，不是「失败」）：
/// - 回包成功 → 结局已定（上游先答先收口），当场撤卡；
/// - `unknown-approval` → 这条审批已经不在了，卡片撤下，一句话说明；
/// - 网络失败 → 卡片转「已发出，结果未知」，`decided` 回流或重开重建时自愈。
///
/// 每次应答带一个客户端生成的 `answerId`（幂等键）：回包丢了重试，
/// 服务端回放第一次的结果，绝不二次投递。
@MainActor
final class ApprovalStore: ObservableObject {

    /// 屏上一张待批卡片。
    struct PendingApproval: Identifiable, Equatable {
        /// `approval/asked` 审计 id；纯转发而来的卡片用 waterfall `eventId` 代替。
        let id: String
        /// 被问的是哪个工具。
        let toolName: String
        /// 提问方给的人话解释，可能没有。
        let reason: String?
        /// 提问挂在哪一次工具调用上，可能没有 —— 转发帧与审计事件的对账键。
        let callId: String?
        /// 网关 `$events` waterfall 帧的 `eventId`（实施期修正 11）——应答的
        /// 线上寻址键。重建出的卡片在对应转发帧到达前是 `nil`（不可应答）。
        var eventId: String?
    }

    /// 一张卡片的应答进展。
    enum AnswerState: Equatable {
        /// 还没动过。
        case idle
        /// 已发出，回包还没到 —— 结果未知。
        case unknown
        /// 已投递，等 `decided` 收口。
        case delivered
    }

    @Published private(set) var pending: [PendingApproval] = []
    /// 每条审批的应答进展（不在 `pending` 里的不存在）。
    @Published private(set) var states: [String: AnswerState] = [:]
    /// 与单条卡片无关的一句话说明（如「审批已被取消」）。
    @Published private(set) var notice: String?

    private let client: GatewayClient
    /// 最近一次重建用的事件 —— `sync` 改了对账状态后要拿它重算，见 `reconcile()`。
    private var lastEvents: [SessionEvent] = []
    /// 转发而来的活卡（eventId → 卡片）；重建时跨窗口保留。
    private var live: [String: PendingApproval] = [:]
    /// 最近一次 sync 对账里上游仍挂着的 callId（实施期修正 12）——重建时
    /// 据此过滤悬空审计卡：上游挂起的审批必然有对应 waterfall，收口后
    /// cancel 帧只发给在线者，dsh 重启更会让 asked 永远等不到 decided。
    private var standingCallIds: Set<String> = []
    /// 名单是否权威。只有收到过非 stale 的 sync 才敢按名单滤卡 —— relay
    /// 未就绪时服务端发 stale 帧，此时 filtering 会把真挂着的审批也滤没。
    private var hasSync = false

    init(client: GatewayClient) {
        self.client = client
    }

    /// 用镜像里的全部事件重建待批集合（asked − decided）。
    ///
    /// 窗口是连续的：asked 之后落下的 decided 必然还在同一窗口里，
    /// 所以这个差集在窗口边界上不产生假阳性。
    func rebuild(from events: [SessionEvent]) {
        lastEvents = events
        reconcile()
    }

    /// 按手头的事件与对账状态重算待批集合。
    ///
    /// 与 `rebuild` 分开，是为了让**对账名单的变化**也能立刻生效：`sync` 帧改的是
    /// `hasSync` / `standingCallIds`，而审计卡的过滤只在重算时跑 —— 不重算的话，
    /// 结论要拖到下一次事件或刷新才落地（真机抓到：残骸卡一直挂在屏上）。
    private func reconcile() {
        var pendingById: [String: PendingApproval] = [:]
        for event in lastEvents {
            switch event.type {
            case "approval/asked":
                guard let id = event.data["id"]?.string,
                      let toolName = event.data["toolName"]?.string else { continue }
                let callId = event.data["callId"]?.string
                // 对账（修正 12）：名单权威时，带 callId 而上游没有的 asked
                // 是悬空审计（收口即有 decided；没有 decided 说明收口方早已
                // 不在），不建卡 —— 不然每次刷新都复活。
                if let callId, hasSync, !standingCallIds.contains(callId) { continue }
                pendingById[id] = PendingApproval(
                    id: id,
                    toolName: toolName,
                    reason: event.data["reason"]?.string,
                    callId: callId,
                    eventId: nil
                )
            case "approval/decided":
                if let id = event.data["id"]?.string { pendingById.removeValue(forKey: id) }
            case "turn/end":
                // 实施期修正 14：turn 闭合 ⇒ 这一轮里还没收口的 asked 是崩溃残骸。
                // 上游 `approval.request()` 在 turn 内一直阻塞到 outcome 落盘
                // （`user-approval/src/index.ts:208-227`：append asked → await
                // decide() → append decided），所以 turn 能结束，就意味着它发起的
                // 每个审批都已有结局。只有进程在等 outcome 的中途被杀，才会留下
                // 「turn 已闭合、decided 永久缺席」的一对 —— 其随后那条
                // `tool/result` 带 `TOOL_OUTCOME_UNKNOWN`（真机产物）。差集把它们
                // 当成待批是假阳性：卡片既不可应答、又永远等不到收口。
                pendingById.removeAll()
            default:
                break
            }
        }
        // 重建以审计差集为骨架；转发而来的活卡合并进来。同题去重：活卡与
        // 审计卡的 callId 相同（同一提问的两面）时，把 eventId 绑到审计卡、
        // 只留一张 —— 不然重进会话必出两张卡。
        var merged = Array(pendingById.values)
        for (eventId, card) in live {
            if let callId = card.callId,
               let idx = merged.firstIndex(where: { $0.callId == callId && $0.eventId == nil }) {
                merged[idx].eventId = eventId
                continue
            }
            if !merged.contains(where: { $0.eventId == eventId }) {
                merged.append(card)
            }
        }
        pending = merged.sorted { $0.id < $1.id }
        // 已不在屏上的状态行一并清掉，免得字典里积着看不见的旧值。
        states = states.filter { key, _ in
            pending.contains(where: { card in card.id == key || card.eventId == key })
        }
    }

    /// 网关审批推送（实施期修正 11）：转发帧到达 → 绑定或新建；取消 → 撤卡。
    func receive(_ payload: JSONValue) {
        switch payload["kind"]?.string {
        case "request":
            guard let eventId = payload["eventId"]?.string,
                  let toolName = payload["toolName"]?.string else { return }
            let reason = payload["reason"]?.string
            let callId = payload["callId"]?.string
            // 绑定：同 callId（最准），退而求其次同 toolName + reason。
            if let idx = pending.firstIndex(where: { card in
                card.eventId == nil
                    && (callId != nil && card.callId == callId
                        || (card.toolName == toolName && card.reason == reason))
            }) {
                pending[idx].eventId = eventId
            } else if !pending.contains(where: { $0.eventId == eventId }) {
                let card = PendingApproval(
                    id: eventId, toolName: toolName,
                    reason: reason, callId: callId, eventId: eventId)
                pending.append(card)
                live[eventId] = card
            }
        case "cancel":
            guard let eventId = payload["eventId"]?.string else { return }
            pending.removeAll { $0.eventId == eventId }
            live.removeValue(forKey: eventId)
            states[eventId] = nil
        case "sync":
            // 连接即对账（实施期修正 12）。三档：
            // - stale：relay 未就绪，名单证明不了任何事 —— 不撤卡、不启用
            //   callId 过滤（对空名单过滤会把真挂着的审批也滤没）。
            // - 旧服务端格式（只有 eventIds，无 callIds）：eventIds 照样
            //   用于撤转发卡；callId 过滤保持关闭（审计卡保守保留）。
            // - 权威名单：撤名单之外的转发卡，并记 callIds 供 rebuild 过滤
            //   悬空审计卡。
            guard let ids = payload["eventIds"]?.array else { return }
            if payload["stale"]?.bool == true {
                hasSync = false
                standingCallIds = []
                reconcile()
                return
            }
            let standing = Set(ids.compactMap { $0.string })
            pending.removeAll { card in
                guard let eventId = card.eventId else { return false } // 审计卡交给 reconcile 对账
                if standing.contains(eventId) { return false }
                live.removeValue(forKey: eventId)
                states[eventId] = nil
                return true
            }
            if let callIds = payload["callIds"]?.array {
                hasSync = true
                standingCallIds = Set(callIds.compactMap { $0.string })
            }
            // 名单变了就可能改变审计卡的判定 —— 当场重算，不等下一次刷新。
            reconcile()
        default:
            break
        }
    }

    /// 应答一条待批审批。按钮点击 → 状态流转 → 服务端投递。
    /// 寻址键 = 绑定到的 waterfall `eventId`；还没绑上的卡片（重建出的、
    /// 转发帧未到）不能应答 —— 如实说明，而不是把审计 id 冒充线上键。
    func answer(_ approval: PendingApproval, allow: Bool) async {
        guard states[approval.id] == nil || states[approval.id] == .idle else { return }
        guard let eventId = approval.eventId else {
            notice = "这条审批还没有经由网关转发到手机 —— 请在 Mac 上处理，或稍候重进会话。"
            return
        }
        do {
            try await client.answerApproval(eventId: eventId, allow: allow, answerId: UUID().uuidString)
            // 自清（运行时实锤：receiveRemoteEventResult 先移除应答者自己的
            // delivery 再广播 cancel —— 自己答掉的审批，cancel 只发给别人，
            // 我们永远收不到收口帧）。上游语义「先答先收口」，回包成功即结局
            // 已定，与 Web UI 同样在应答当下收掉卡片。
            pending.removeAll { $0.eventId == eventId }
            live.removeValue(forKey: eventId)
            states[approval.id] = nil
            notice = "已投递：\(allow ? "允许" : "拒绝")"
        } catch GatewayClientError.refused(let failure) where failure.code == GatewayErrorCode.unknownApproval.rawValue {
            // 审批已不在：撤卡，把话说清楚。真正的结局以 decided 为准，
            // 它若还没回流，重开会话重建时会看见。
            notice = failure.readableDescription
            pending.removeAll { $0.id == approval.id }
            states[approval.id] = nil
        } catch {
            // 传输失败 ≠ 未生效：如实转「未知」，等 decided 收口。
            states[approval.id] = .unknown
        }
    }
}
