/**
 * 待批审批的判定：给一串会话事件、三种转发帧与一份对账名单，算出「还挂着哪些」。
 *
 * 纯值类型，不 import SwiftUI、**不认识客户端** —— 构造它不需要网关、不需要界面
 * （`tests/ApprovalReconcileTests.swift` 直接 `ApprovalInbox()`）。事实来源与会话内容同一条：
 * 会话日志 —— `approval/asked` 挂起一个问题，`approval/decided`（无论谁答的、什么结局）收口它。
 * 重建就是「asked 减去 decided」，输入永远是窗口事件，不自持一份真相。
 *
 * **三个入口，一个派生**：`rebuild(from:)` 收整份窗口事件，`absorb(_:)` 收转发帧与对账名单，
 * `remove(id:)` 记下「这张卡已经有结局」。三者都只改输入，最后由 `reconcile()` 重算 ——
 * `pending` 只在 `reconcile()` 里被赋值。**卡上的寻址键是算出来的，不是补上去的**：只要它还能
 * 被补写，下一次刷新就会把它抹掉（R17：`refreshView` 每次刷新都调 `rebuild`）。
 *
 * `remove(id:)` 的调用者是宿主：它按应答的结局决定何时移除。本类型不知道「为什么删」，
 * 也不认识应答与结局这些概念 —— 那是编排侧的事（R16 期2 决定 C1）。
 *
 * 判定规则与搬家前逐字相同（M5 §3.3 表 + 实施期修正 14）：Q1–Q7 七条断言，外加转发帧与 R17 的
 * 断言（绑定活过重建 / 收口不复活 / 配对 / 可应答性 / 名单与帧的先后 / 已答掉的不抢帧），都在
 * `tests/ApprovalReconcileTests.swift`。
 *
 * 消费者：`ApprovalStore`（持它、把 `pending` 发布成可观察属性）、`ApprovalCard`（读
 * `PendingApproval` 与它的 `canAnswer`）。
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
        /// 提问挂在哪一次工具调用上，可能没有 —— 转发帧与审计事件配对的键。
        let callId: String?
        /// 网关 `$events` waterfall 帧的 `eventId` —— 应答的线上寻址键；
        /// 重建出的卡片在转发帧到达前为 `nil`。它是重算出来的，不是构造后补上去的。
        let eventId: String?

        /// 能不能应答。视图与宿主读同一份：卡上出现按钮 ⇔ 按下会发出请求。
        var canAnswer: Bool { eventId != nil }
    }

    private(set) var pending: [PendingApproval] = []

    /// 最近一次重建用的事件 —— 名单变化时凭它重算，所以必须整份留着而不是只留增量。
    private var lastEvents: [SessionEvent] = []
    /// 转发而来的帧，按到达顺序（配对时按序取最早未配对的）。
    private var forwarded: [PendingApproval] = []
    /// 最近一次 sync 对账里上游仍挂着的 callId —— 重建时据此过滤悬空审计卡：收口后
    /// cancel 只发给在线者，dsh 重启更让 asked 永无 decided。
    private var standingCallIds: Set<String> = []
    /// 名单是否权威。只有收到过非 stale 的 sync 才敢按名单滤卡 —— relay 未就绪时服务端发 stale 帧。
    private var hasSync = false
    /// 已经有结局的审计 id（`cancel` 或本地应答成功）。它不来自日志：本地应答成功时
    /// `decided` 还没落盘，所以只能单独记。
    private var settledIds: Set<String> = []

    /// 用全部窗口事件重建（asked − decided）。窗口连续 —— asked 之后落下的 decided 必在同一
    /// 窗口里，故差集在窗口边界上不产生假阳性。
    mutating func rebuild(from events: [SessionEvent]) {
        lastEvents = events
        reconcile()
    }

    /// 吸收一条网关审批推送：转发帧到达 → 记下；取消 → 撤帧并记下结局；对账 → 换名单。最后都重算。
    mutating func absorb(_ frame: JSONValue) {
        switch frame["kind"]?.string {
        case "request":
            guard let eventId = frame["eventId"]?.string,
                  let toolName = frame["toolName"]?.string else { return }
            let card = PendingApproval(
                id: eventId, toolName: toolName,
                reason: frame["reason"]?.string,
                callId: frame["callId"]?.string,
                eventId: eventId)
            // 重连会补投全部仍挂起的问题 —— 按 eventId 去重，原位更新。
            if let index = forwarded.firstIndex(where: { $0.id == eventId }) {
                forwarded[index] = card
            } else {
                forwarded.append(card)
            }
            // 帧是「这次提问此刻还挂在网关上」的证据。名单只是连接那一刻的快照，之后新增的
            // 审批不在里面 —— 不并进来，下一次重算会把它当成悬空审计滤掉，连帧一起消失。
            if let callId = card.callId { standingCallIds.insert(callId) }
            reconcile()
        case "cancel":
            guard let eventId = frame["eventId"]?.string else { return }
            // 先问「这帧配的是哪条提问」，再删帧 —— 提问若在日志里，它的结局要留住。
            if let auditId = askId(of: eventId) { settledIds.insert(auditId) }
            forwarded.removeAll { $0.id == eventId }
            reconcile()
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
            forwarded.removeAll { !standing.contains($0.id) }
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

    /// 把一条卡从待批集合里拿掉，并记下「它已经有结局」。调用者是宿主；本类型不问为什么。
    mutating func remove(id: String) {
        guard let card = pending.first(where: { $0.id == id }) else { return }
        if let eventId = card.eventId {
            // 独立帧卡（`id == eventId`）不带审计 id；把它的提问也记上，免得随后进窗口的
            // 审计卡又复活一张按不动的。
            if let auditId = askId(of: eventId) { settledIds.insert(auditId) }
            forwarded.removeAll { $0.id == eventId }
        }
        settledIds.insert(id)
        reconcile()
    }

    // MARK: - 判定

    /// 日志里的一个问题。`closed` = 它已有结局（`decided`、它所在的 turn 已闭合、或本地已应答）。
    private struct Ask {
        let id: String
        let toolName: String
        let reason: String?
        let callId: String?
        var closed: Bool
    }

    /// 扫一遍事件，按日志顺序列出问过的问题。`settled` 里的 id 直接算已收口 —— 它们排到
    /// 配对顺序的第二档，不会把帧从还挂着的那条手里抢走。
    private static func asks(in events: [SessionEvent], settled: Set<String>) -> [Ask] {
        var asks: [Ask] = []
        for event in events {
            switch event.type {
            case "approval/asked":
                guard let id = event.data["id"]?.string,
                      let toolName = event.data["toolName"]?.string else { continue }
                let ask = Ask(id: id, toolName: toolName,
                              reason: event.data["reason"]?.string,
                              callId: event.data["callId"]?.string,
                              closed: settled.contains(id))
                // 同一 id 重发时后到者为准，不产生两张同 id 的卡。
                if let index = asks.firstIndex(where: { $0.id == id }) {
                    asks[index] = ask
                } else {
                    asks.append(ask)
                }
            case "approval/decided":
                guard let id = event.data["id"]?.string else { continue }
                for index in asks.indices where asks[index].id == id { asks[index].closed = true }
            case "turn/end":
                // turn 闭合 ⇒ 这一轮里还没收口的 asked 是崩溃残骸。上游
                // `approval.request()` 在 turn 内阻塞到 outcome 落盘
                // （`user-approval/src/index.ts:215-233`），故 turn 能结束就意味着它发起的每个
                // 审批都有结局；只有进程在等 outcome 时被杀，才会留下「turn 已闭合、decided
                // 永久缺席」的一对（随后那条 `tool/result` 带 `TOOL_OUTCOME_UNKNOWN`，真机产物）。
                for index in asks.indices { asks[index].closed = true }
            default:
                break
            }
        }
        return asks
    }

    /// 把转发帧配到提问上：返回「审计 id → eventId」。
    ///
    /// 两档。先按 `callId`（两侧都有且相等才配）；配不上的再按「工具名 + 理由」加到达顺序，
    /// 但**只在至少一侧没有 `callId` 时**才允许 —— 两侧都有且不同，就是两次工具调用，
    /// 文字相同是巧合，配上等于把答案投给另一次提问。
    ///
    /// 未收口的提问先挑帧：帧是「这一问还活着」的证据；让已收口的旧提问先挑走唯一的帧，
    /// 活着的提问会变成不可应答，而帧被丢掉。
    private static func pairs(asks: [Ask], forwarded: [PendingApproval]) -> [String: String] {
        var pairs: [String: String] = [:]
        var used = Set<String>()
        let ordered = asks.filter { !$0.closed } + asks.filter { $0.closed }
        for ask in ordered {
            guard let callId = ask.callId else { continue }
            guard let frame = forwarded.first(where: {
                !used.contains($0.id) && $0.callId == callId
            }) else { continue }
            pairs[ask.id] = frame.id
            used.insert(frame.id)
        }
        for ask in ordered where pairs[ask.id] == nil {
            guard let frame = forwarded.first(where: {
                !used.contains($0.id)
                    && $0.toolName == ask.toolName
                    && $0.reason == ask.reason
                    && (ask.callId == nil || $0.callId == nil)
            }) else { continue }
            pairs[ask.id] = frame.id
            used.insert(frame.id)
        }
        return pairs
    }

    /// 这一帧配的是哪条提问（`cancel` 要把它记成已有结局）。
    private func askId(of eventId: String) -> String? {
        Self.pairs(asks: Self.asks(in: lastEvents, settled: settledIds),
                   forwarded: forwarded)
            .first { $0.value == eventId }?.key
    }

    /// 从事件与转发帧重算待批集合 —— 唯一的写入口。
    ///
    /// 与 `rebuild` 分开，是为了让**对账名单的变化**也立刻生效：`sync` 帧改 `hasSync` /
    /// `standingCallIds`，而过滤只在重算时跑 —— 不重算的话结论要拖到下次事件或刷新才落地
    /// （真机抓到：残骸卡一直挂在屏上）。
    private mutating func reconcile() {
        let asks = Self.asks(in: lastEvents, settled: settledIds)
        let pairs = Self.pairs(asks: asks, forwarded: forwarded)
        var cards: [PendingApproval] = []
        var concealed: Set<String> = []
        for ask in asks {
            if ask.closed { continue }
            // 对账（修正 12）：名单权威时，带 callId 而上游没有的 asked 是悬空审计
            // （收口即有 decided；没有 decided 说明收口方早已不在），不建卡 —— 不然每次刷新都复活。
            if let callId = ask.callId, hasSync, !standingCallIds.contains(callId) {
                concealed.insert(ask.id)
                continue
            }
            cards.append(PendingApproval(id: ask.id, toolName: ask.toolName, reason: ask.reason,
                                         callId: ask.callId, eventId: pairs[ask.id]))
        }
        // 配到提问的帧已经成了那张卡的寻址键；没配上的帧自成一张卡（它可能是窗口外的提问）。
        // 被名单藏起来的提问不吃帧 —— 名单只是连接那一刻的快照，帧才是「此刻还挂着」的证据。
        let consumed = Set(pairs.filter { !concealed.contains($0.key) }.values)
        for frame in forwarded where !consumed.contains(frame.id) { cards.append(frame) }
        pending = cards.sorted { $0.id < $1.id }
    }
}
