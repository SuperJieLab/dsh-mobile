/**
 * 会话组装的引擎 —— 只认识「格子」与「顺序」，不认识任何业务词汇。
 *
 * 三条硬约束就是这一层的全部价值（它们合起来让「定稿」不必删除重建）：
 * ① 一个格子的身份是 `(kind, id)`，与内容无关；
 * ② `start` 只认窗口里最早的那条，之后所有命中（含迟到的第二条 start）都走 `update`；
 * ③ 已经物化过的节点不许撤回 —— 要暂时离开可见流只能转 `hidden`。
 *
 * 三条路径按事件怎么进来分：`rebuild`（打开 / 重连 / 缺口修复）、`append`（实时新增）、
 * `prepend`（往回翻一页）。第三条不许重建既有格子，这是「翻页不重挂」的全部内容。
 */
import Foundation

struct ConversationAssembler {

    private struct Context {
        let key: String
        let kind: String
        let id: String
        let definition: AnyNodeDefinition
        var start: ConversationMatch?
        var matches: [ConversationMatch] = []
        var state: Any?
        var current: ChatNode?
    }

    private struct PendingHit {
        let definition: AnyNodeDefinition
        let id: String
        let match: ConversationMatch
    }

    private let definitions: [AnyNodeDefinition]
    /// 不变量被破坏时的出口。引擎不认识日志，也不该认识 —— 判定在这里，去向由驱动方给。
    ///
    /// 为什么要有它：`assertionFailure` 在 Release 里被优化掉，那时症状是「少一行 / 视图错位」，
    /// 没有任何线索。往这里报一条，至少能定位到是哪个 kind 的哪个格子。
    private let onAnomaly: ((String, [String: String]) -> Void)?
    private var contexts: [String: Context] = [:]
    private var inputs: [EventOrder: AssemblyEvent] = [:]
    private var locationIndex = LocationIndex()

    init(definitions: [AnyNodeDefinition], onAnomaly: ((String, [String: String]) -> Void)? = nil) {
        self.definitions = definitions
        self.onAnomaly = onAnomaly
    }

    /// 一段事件的边界 —— 只有它变化会推动整条时间线。
    private static func isLocationBoundary(_ type: String) -> Bool {
        type == "turn/start" || type == "turn/end" || type == "step/start" || type == "step/end"
    }

    // MARK: - 三条路径

    /// 重建整段窗口。打开、重连、缺口修复走这条 —— 身份全部重来，这是「重置」的语义。
    @discardableResult
    mutating func rebuild(_ events: [AssemblyEvent]) -> Change {
        contexts.removeAll()
        inputs.removeAll()
        let sorted = events.sorted { $0.order < $1.order }
        for event in sorted { inputs[event.order] = event }
        locationIndex.rebuild(sorted)
        for event in sorted { dispatch(event) }
        return .full(.immediate)
    }

    /// 追加一条实时事件。不扫描既有格子。
    ///
    /// 非边界事件说得清自己变了哪些槽位（命中的 key 就是全部变化）；边界事件会推动整条
    /// 时间线，`rebuildLocations()` 改到的是任意槽位，所以只能报「说不清」。
    @discardableResult
    mutating func append(_ event: AssemblyEvent) -> Change {
        guard inputs[event.order] == nil else { return .none }
        inputs[event.order] = event
        let boundary = Self.isLocationBoundary(event.type)
        if boundary { rebuildLocations() }
        let change = dispatch(event)
        guard !boundary else { return .full(Publication.maximum(change.publication, .immediate)) }
        return change
    }

    /// 往回翻一页。既有格子的 key 与 state 逐条保留，只有受影响的格子重算。
    ///
    /// **报「说不清」**：`rebuildLocations()` 会改写**所有**槽位的匹配位置，不只是新事件
    /// 命中的那几个；位置又是匹配的一部分（过程行按位置滤条目、`isLastStep` 读起点位置），
    /// 所以「命中集」不等于「变化集」。要把它变成增量，得先做位置索引的增量。
    @discardableResult
    mutating func prepend(_ events: [AssemblyEvent]) -> Change {
        let fresh = events
            .filter { inputs[$0.order] == nil }
            .sorted { $0.order < $1.order }
        guard !fresh.isEmpty else { return .none }
        for event in fresh { inputs[event.order] = event }
        rebuildLocations()

        var pending: [String: [PendingHit]] = [:]
        var publication = Publication.none
        for event in fresh {
            for hit in hits(of: event) {
                pending[hit.key, default: []].append(PendingHit(definition: hit.definition, id: hit.id, match: hit.match))
                publication = Publication.maximum(publication, hit.publication)
            }
        }
        for (key, hits) in pending { merge(hits, into: key) }
        return .full(Publication.maximum(publication, .immediate))
    }

    /// 一次未定稿输出收笔：撤掉这个 attempt 的未定稿命中，可选地接下持久定稿事件。
    ///
    /// 撤掉之后留下的空格子**不删** —— 它继续占着身份，定义自己决定转不转 `hidden`。
    ///
    /// 带定稿时走 `rebuildLocations()`，所以报「说不清」；只撤草稿时变化集就是被波及的槽位。
    @discardableResult
    mutating func settleAssistant(attemptId: String, settlement: AssemblyEvent? = nil) -> Change {
        var affected: Set<String> = []
        var retiredOrders: Set<EventOrder> = []
        let retired = inputs.filter { Self.attemptId(of: $0.value) == attemptId }.map(\.key)
        for order in retired {
            retiredOrders.insert(order)
            inputs.removeValue(forKey: order)
        }
        for (key, context) in contexts {
            let remaining = context.matches.filter { !retiredOrders.contains($0.event.order) }
            guard remaining.count != context.matches.count else { continue }
            contexts[key]?.matches = remaining
            affected.insert(key)
        }
        var publication: Publication = retiredOrders.isEmpty ? .none : .immediate
        var rebuilt = false
        if let settlement, inputs[settlement.order] == nil {
            inputs[settlement.order] = settlement
            rebuildLocations()
            publication = Publication.maximum(publication, dispatch(settlement).publication)
            rebuilt = true
        }
        for key in affected { replay(key) }
        return rebuilt
            ? .full(publication)
            : Change(publication: publication, touched: affected, rebuilt: false)
    }

    // MARK: - 物化

    /// 当前的节点集合（含 hidden），顺序由排序层给。
    func nodes() -> [ChatNode] {
        contexts.values.compactMap { context in
            let snapshot = NodeContext<Any>(
                key: context.key,
                kind: context.kind,
                id: context.id,
                matches: context.matches,
                start: context.start,
                state: context.state,
                current: context.current
            )
            return context.definition.buildViewNode(snapshot)
        }
    }

    /// 一条事件都没有 —— 驱动方据此判「这是第一次喂」。
    var isEmpty: Bool { inputs.isEmpty }

    /// 已经有事件进去了吗、边界在哪 —— 驱动方据此判「这一发是追加还是前插」。
    func contains(order: EventOrder) -> Bool { inputs[order] != nil }

    /// 持久事件的序号区间。未定稿事件（小数序号）不算 —— 它随时会被撤掉。
    var bounds: (min: EventOrder, max: EventOrder)? {
        var low: EventOrder?
        var high: EventOrder?
        for event in inputs.values where event.seq != nil {
            low = Swift.min(low ?? event.order, event.order)
            high = Swift.max(high ?? event.order, event.order)
        }
        guard let low, let high else { return nil }
        return (low, high)
    }

    // MARK: - 分发与回放

    private struct Hit {
        let key: String
        let definition: AnyNodeDefinition
        let id: String
        let match: ConversationMatch
        let publication: Publication
    }

    /// 一个事件问一遍所有定义：各自认不认、什么角色、在哪。
    ///
    /// 一条事件可以被多份定义同时认领（`assistant/message` 既更新 assistant-step 的槽位，
    /// 又给过程段添一行文本）—— 这正是「定义之间互不知道」的代价与好处：
    /// 代价是同一个事件被算两遍，好处是新增一种节点不必改已有的定义。
    private func hits(of event: AssemblyEvent) -> [Hit] {
        let location = locationIndex.locationOf(event)
        return definitions.compactMap { definition in
            guard let result = definition.match(event) else { return nil }
            let match = ConversationMatch(event: event, role: result.role, location: location)
            return Hit(
                key: conversationContextKey(kind: definition.kind, id: result.id),
                definition: definition,
                id: result.id,
                match: match,
                publication: definition.publication(match)
            )
        }
    }

    @discardableResult
    private mutating func dispatch(_ event: AssemblyEvent) -> Change {
        var change = Change.none
        for hit in hits(of: event) {
            change.touched.insert(hit.key)
            change.publication = Publication.maximum(change.publication, accept(hit))
        }
        return change
    }

    private mutating func accept(_ hit: Hit?) -> Publication {
        guard let hit else { return .none }
        var context = contexts[hit.key] ?? Context(
            key: hit.key, kind: hit.definition.kind, id: hit.id, definition: hit.definition
        )
        let starting = hit.match.role == .start && context.start == nil
        if let previous = context.matches.last, previous.event.order >= hit.match.event.order {
            assertionFailure("conversation invariant: non-monotonic match for \(hit.key)")
            onAnomaly?("non-monotonic-match", ["kind": hit.definition.kind, "id": hit.id,
                                                "order": String(hit.match.event.order)])
        }
        if starting, !context.matches.isEmpty {
            // 早于它的 update 已经在格子里了（前插补齐、或草稿比 step/start 先到）。
            // 不能把这条当 update 丢掉：那样 state 永远建不起来，整段静默消失。
            // 记一条异常，然后按「先 start、再按 order 依次 apply」重放 —— 早到的那几条
            // 仍然算这个格子的内容，只是顺序由 order 决定。
            onAnomaly?("start-after-match", ["kind": hit.definition.kind, "id": hit.id,
                                                  "order": String(hit.match.event.order)])
        }
        if let last = context.matches.last, hit.match.event.order < last.event.order {
            contexts[hit.key] = context
            merge([PendingHit(definition: hit.definition, id: hit.id, match: hit.match)], into: hit.key)
            return hit.publication
        }
        context.matches.append(hit.match)
        if starting { context.start = hit.match }
        contexts[hit.key] = context

        if starting || context.state == nil {
            replay(hit.key)
        } else if let state = context.state {
            let snapshot = NodeContext<Any>(
                key: context.key, kind: context.kind, id: context.id,
                matches: context.matches, start: context.start, state: state, current: context.current
            )
            contexts[hit.key]?.state = context.definition.update(snapshot, hit.match)
        }
        materialize(hit.key)
        return hit.publication
    }

    /// 从窗口里最早的那条 start 重放整格。
    ///
    /// state 被整份重算，不是打补丁 —— 前插补齐后只有这样才能一致。
    private mutating func replay(_ key: String) {
        guard var context = contexts[key] else { return }
        context.matches.sort { $0.event.order < $1.event.order }
        context.start = context.matches.first { $0.role == .start }
        guard let start = context.start else {
            // 只有 update、start 还没到：保留格子，state 留空（pending 语义）。
            context.state = nil
            contexts[key] = context
            return
        }
        var state = context.definition.start(
            NodeContext<Any>(key: context.key, kind: context.kind, id: context.id,
                             matches: context.matches, start: start, state: nil, current: context.current),
            start
        )
        for match in context.matches where match.event.order != start.event.order {
            state = context.definition.update(
                NodeContext<Any>(key: context.key, kind: context.kind, id: context.id,
                                 matches: context.matches, start: start, state: state, current: context.current),
                match
            )
        }
        context.state = state
        contexts[key] = context
        materialize(key)
    }

    /// 前插：把新命中并进既有格子，再整格重放。既有格子的 key 不变。
    private mutating func merge(_ hits: [PendingHit], into key: String) {
        guard let first = hits.first else { return }
        var context = contexts[key] ?? Context(
            key: key, kind: first.definition.kind, id: first.id, definition: first.definition
        )
        context.matches.append(contentsOf: hits.map(\.match))
        contexts[key] = context
        replay(key)
    }

    private mutating func materialize(_ key: String) {
        guard let context = contexts[key] else { return }
        let snapshot = NodeContext<Any>(
            key: context.key, kind: context.kind, id: context.id,
            matches: context.matches, start: context.start, state: context.state, current: context.current
        )
        let node = context.definition.buildViewNode(snapshot)
        if node == nil, context.current != nil {
            // 撤回已物化的节点等于删除重建 —— 定义该返回同一个 key + hidden。
            assertionFailure("conversation invariant: \(context.kind) withdrew a materialized node")
            onAnomaly?("withdrawn-node", ["kind": context.kind, "id": context.id])
            contexts[key]?.current = context.current.map {
                ChatNode(key: $0.key, kind: $0.kind, businessId: $0.businessId, anchorSeq: $0.anchorSeq,
                         visibility: .hidden, data: $0.data)
            }
            return
        }
        contexts[key]?.current = node
    }

    private mutating func rebuildLocations() {
        let sorted = inputs.values.sorted { $0.order < $1.order }
        locationIndex.rebuild(sorted)
        // 位置是匹配的一部分：边界事件后到（例如 `turn/end` 补上）要回填到既有命中上。
        for (key, context) in contexts {
            let refreshed = context.matches.map { match in
                ConversationMatch(event: match.event, role: match.role,
                                  location: locationIndex.locationOf(match.event))
            }
            guard refreshed != context.matches else { continue }
            contexts[key]?.matches = refreshed
            contexts[key]?.start = refreshed.first { $0.role == .start }
        }
    }

    private static func attemptId(of event: AssemblyEvent) -> String? {
        event.data["attemptId"]?.string
    }
}
