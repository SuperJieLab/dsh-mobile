/**
 * 待批审批的判定：给一串会话事件、三种转发帧与一份对账名单，算出「还挂着哪些」。
 *
 * 纯值类型，不 import SwiftUI、**不认识客户端** —— 构造它不需要网关、不需要界面
 * （`tests/ApprovalReconcileTests.swift` 直接 `ApprovalInbox()`）。事实来源与会话内容同一条：
 * 会话日志 —— `approval/asked` 挂起一个问题，`approval/decided`（无论谁答的、什么结局）收口它。
 * 重建就是「asked 减去 decided」，输入永远是窗口事件，不自持一份真相。
 *
 * 两个入口，一个重算：`rebuild(from:)` 收整份窗口事件（留一份，名单变化时凭它重算），
 * `absorb(_:)` 收转发帧（只改增量状态），两者最后都落到 `reconcile()` —— 读这两个入口时
 * 记住它们在 `reconcile()` 会合，不要以为各有一套规则。
 *
 * `remove(id:)` 的调用者是宿主：它按应答的结局决定何时移除。本类型不知道「为什么删」，
 * 也不认识应答与结局这些概念 —— 那是编排侧的事（R16 期2 决定 C1）。
 *
 * 判定规则与搬家前逐字相同（M5 §3.3 表 + 实施期修正 14）：Q1–Q7 七条断言，外加一条转发帧
 * （`request` 绑定 / `cancel` 撤卡），都在 `tests/ApprovalReconcileTests.swift`。
 */
struct ApprovalInbox {

    /// 待批的一张卡片。
    struct PendingApproval: Identifiable, Equatable {
        /// `approval/asked` 审计 id；纯转发而来的卡片用 waterfall `eventId` 代替。
        let id: String
        /// 被问的是哪个工具。
        let toolName: String
        /// 提问方给的人话解释，可能没有。
        let reason: String?
        /// 提问挂在哪一次工具调用上，可能没有 —— 转发帧与审计事件的对账键。
        let callId: String?
        /// 网关 `$events` waterfall 帧的 `eventId` —— 应答的线上寻址键；
        /// 重建出的卡片在转发帧到达前为 `nil`（不可应答）。
        var eventId: String?
    }

    private(set) var pending: [PendingApproval] = []

    /// 最近一次重建用的事件 —— 名单变化时凭它重算，所以必须整份留着而不是只留增量。
    private var lastEvents: [SessionEvent] = []
    /// 转发而来的活卡（eventId → 卡片）；重建时跨窗口保留。
    private var live: [String: PendingApproval] = [:]
    /// 最近一次 sync 对账里上游仍挂着的 callId —— 重建时据此过滤悬空审计卡：收口后
    /// cancel 只发给在线者，dsh 重启更让 asked 永无 decided。
    private var standingCallIds: Set<String> = []
    /// 名单是否权威。只有收到过非 stale 的 sync 才敢按名单滤卡 —— relay 未就绪时服务端发 stale 帧。
    private var hasSync = false

    /// 用全部窗口事件重建（asked − decided）。窗口连续 —— asked 之后落下的 decided 必在同一
    /// 窗口里，故差集在窗口边界上不产生假阳性。
    mutating func rebuild(from events: [SessionEvent]) {
        lastEvents = events
        reconcile()
    }

    /// 吸收一条网关审批推送：转发帧到达 → 绑定或新建；取消 → 撤卡；对账 → 重算。
    mutating func absorb(_ frame: JSONValue) {
        switch frame["kind"]?.string {
        case "request":
            guard let eventId = frame["eventId"]?.string,
                  let toolName = frame["toolName"]?.string else { return }
            let reason = frame["reason"]?.string
            let callId = frame["callId"]?.string
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
            guard let eventId = frame["eventId"]?.string else { return }
            pending.removeAll { $0.eventId == eventId }
            live.removeValue(forKey: eventId)
        case "sync":
            // 连接即对账。三档：stale（relay 未就绪，名单证明不了任何事 ——
            // 不撤卡、不启用 callId 过滤，对空名单过滤会把真挂着的审批也滤没）；旧服务端格式
            // （只有 eventIds 无 callIds，eventIds 照样撤转发卡、callId 过滤保持关闭）；权威名单
            // （撤名单之外的转发卡，并记 callIds 供 reconcile 过滤悬空审计卡）。
            guard let ids = frame["eventIds"]?.array else { return }
            if frame["stale"]?.bool == true {
                hasSync = false
                standingCallIds = []
                reconcile()
                return
            }
            let standing = Set(ids.compactMap { $0.string })
            pending.removeAll { card in
                guard let eventId = card.eventId else { return false } // 审计卡交给 reconcile
                if standing.contains(eventId) { return false }
                live.removeValue(forKey: eventId)
                return true
            }
            if let callIds = frame["callIds"]?.array {
                hasSync = true
                standingCallIds = Set(callIds.compactMap { $0.string })
            }
            // 名单变了就可能改变审计卡的判定 —— 当场重算，不等下一次刷新。
            reconcile()
        default:
            break
        }
    }

    /// 把一条卡从待批集合里拿掉。调用者是宿主（应答已有结局时）；本类型不问为什么。
    mutating func remove(id: String) {
        guard let card = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        if let eventId = card.eventId { live.removeValue(forKey: eventId) }
    }

    /// 按手头的事件与对账状态重算待批集合。
    ///
    /// 与 `rebuild` 分开，是为了让**对账名单的变化**也立刻生效：`sync` 帧改 `hasSync` /
    /// `standingCallIds`，而过滤只在重算时跑 —— 不重算的话结论要拖到下次事件或刷新才落地
    /// （真机抓到：残骸卡一直挂在屏上）。
    private mutating func reconcile() {
        var pendingById: [String: PendingApproval] = [:]
        for event in lastEvents {
            switch event.type {
            case "approval/asked":
                guard let id = event.data["id"]?.string,
                      let toolName = event.data["toolName"]?.string else { continue }
                let callId = event.data["callId"]?.string
                // 对账（修正 12）：名单权威时，带 callId 而上游没有的 asked 是悬空审计
                // （收口即有 decided；没有 decided 说明收口方早已不在），不建卡 ——
                // 不然每次刷新都复活。
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
                // turn 闭合 ⇒ 这一轮里还没收口的 asked 是崩溃残骸。上游
                // `approval.request()` 在 turn 内阻塞到 outcome 落盘
                // （`user-approval/src/index.ts:208-227`），故 turn 能结束就意味着它发起的每个
                // 审批都有结局；只有进程在等 outcome 时被杀，才会留下「turn 已闭合、decided
                // 永久缺席」的一对（随后那条 `tool/result` 带 `TOOL_OUTCOME_UNKNOWN`，真机产物）。
                // 差集把它们当待批是假阳性：既不可应答、又等不到收口。
                pendingById.removeAll()
            default:
                break
            }
        }
        // 重建以审计差集为骨架，转发而来的活卡合并进来；同 callId（同一提问的两面）时把 eventId
        // 绑到审计卡、只留一张 —— 不然重进会话必出两张卡。
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
    }
}
