/**
 * 一轮的过程 —— 思考、工具调用、中间文本，按事件顺序。
 *
 * 一轮一个格子（身份是 `turn`），不按「这一轮里的第几段」编号：分段是显示层的事，
 * 上游靠 Group 承担，我们不搬那一层就干脆不分段 —— 同一轮的过程都在这一个节点里。
 *
 * 一条条目归谁画：**最后一步**的文本是这个轮的答案，由 `AssistantStepDefinition` 画，
 * 这里在物化时把它们滤掉；其余步的文本留在这里。滤在物化而不是在累积时就丢，
 * 因为「哪一步是最后一步」会随新事件变 —— 丢早了，那一步变成中间步时文字就找不回来了。
 */
import Foundation

/// 一次工具调用的显示行。四种状态齐全，半截配对如实退化、不猜。
struct ToolRow: Equatable {

    enum Status: Equatable {
        case running
        case succeeded
        case failed
        /// 轮次已关闭而这条调用一直没有结果；上游把它合成为一条 `interrupted` 失败结果。
        case interrupted
    }

    /// 配对键。`tool/call` 与 `tool/result` 靠它认亲。
    let callId: String
    /// 工具名。`nil` = `tool/call` 不在窗口里（只看到结果）—— 不编一个。
    let name: String?
    /// 一行摘要，从参数里按候选键挑。同样可以是「不知道」。
    let summary: String?
    /// 模型给的原始参数（原样 JSON 文本），展开时看。
    let argumentsRaw: String?
    /// 工具返回的正文，展开时看。
    var resultText: String?
    /// 失败时上游给的错误码（`data.error.code`）。
    var errorCode: String?
    var status: Status
    /// 所在步骤号 —— 判「中断」时要看它关没关。
    let step: Int?
    /// 这一行的位置：`tool/call` 的 `seq`；只有结果时是 `tool/result` 的 `seq`。
    let seq: Int
    let time: Double
}

/// 过程里的一行。
enum ProcessEntry: Equatable {
    case thinking(seq: Int, step: Int?, index: Int, text: String, time: Double)
    case tool(ToolRow)
    case text(seq: Int, step: Int?, index: Int, text: String, time: Double)


    /// 这一行在列表里的位置。过程条目都来自持久事件，所以 `seq` 就是位置。
    var order: EventOrder {
        switch self {
        case .thinking(let seq, _, _, _, _), .text(let seq, _, _, _, _): return EventOrder(seq)
        case .tool(let row): return EventOrder(row.seq)
        }
    }
}

extension ProcessEntry: Identifiable {
    /// 取事件 seq，不取组内偏移 —— 往回翻会插入更早的行，偏移整体挪位，seq 不会。
    /// 前缀带种类：同一条助手消息能同时产出「思考」与「文本」两行。
    var id: String {
        switch self {
        // 带块下标：同一条助手消息里可能有两个文本块，只带 seq 会让 ForEach 收到重复身份。
        case .thinking(let seq, _, let index, _, _): return "thinking-\(seq)-\(index)"
        case .text(let seq, _, let index, _, _): return "text-\(seq)-\(index)"
        case .tool(let row): return "tool-\(row.seq)"
        }
    }
}

/// 一轮过程的数据：有没有折叠头 + 逐行条目。折叠头上那句话归 `Display/ProcessText`。
struct ProcessSegment: Equatable {
    let hasHeader: Bool
    let entries: [ProcessEntry]
}

struct ProcessNodeData: Equatable {
    let turn: Int
    /// 一轮只有一段。留着「段」这个形状而不是直接摊平，是因为折叠头与条目本来就是两件东西
    /// （摘要从条目算，标题属于整轮）。
    let segment: ProcessSegment
}

struct ProcessDefinition: ConversationNodeDefinition {

    struct State: Equatable {
        var turn: Int
        /// 这一轮的开头在窗口里吗 —— 不在就不画折叠头（窗口会从一轮中间切开）。
        var hasHeader: Bool
        var entries: [ProcessEntry] = []
    }

    let kind = "process"

    /// 这些事件都带轮次号，都能开格子。
    ///
    /// 「最早那条当 start」由引擎保证，所以这里不必区分谁先谁后 —— 好处是**窗口从一轮中间
    /// 切开时也能建出过程节点**（旧装配器的「无头组」就是这个意思，少了它整轮过程都不显示）。
    private static let ownedTypes: Set<String> = [
        "turn/start", "turn/end", "step/start", "step/end",
        "tool/call", "tool/result", "assistant/message",
    ]

    func match(_ event: AssemblyEvent) -> MatchResult? {
        guard Self.ownedTypes.contains(event.type), let turn = event.turn else { return nil }
        // 压缩点是「替换这一轮在模型里的样子」，不是过程里的一行。
        if event.type == "assistant/message", event.isReplacement { return nil }
        return MatchResult(id: "\(turn)", role: .start)
    }

    func start(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        let event = match.event
        var state = State(turn: event.turn ?? -1, hasHeader: event.type == "turn/start")
        // start 那条本身就是内容（工具调用、助手消息……），不能只建状态不记它。
        apply(event, contextStep: match.location.stepNumber, into: &state)
        return state
    }

    func update(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        guard var state = context.state else { return start(context, match) }
        if match.event.type == "turn/start" {
            state.hasHeader = true
            return state
        }
        apply(match.event, contextStep: match.location.stepNumber, into: &state)
        return state
    }

    func publication(_ match: ConversationMatch) -> Publication { .immediate }

    func buildViewNode(_ context: NodeContext<State>) -> ChatNode? {
        guard let state = context.state else { return context.current.map(Self.hidden) }
        let entries = Self.visibleEntries(state.entries, in: context)
        guard !entries.isEmpty || context.current != nil else { return nil }
        // 锚点是这一组**第一个可见条目**的位置，不是 `turn/start`：后者排在用户那句之前，
        // 整个折叠（含思考）会跑到提问上面去。减 0.1 是为了与同位置的答案分开 ——
        // 一轮只有一条助手消息时，思考与答案同 `seq`，过程该在前。
        let anchor = entries.first.map { $0.order - 0.1 }
            ?? context.start?.event.order
            ?? context.matches.first?.event.order
            ?? 0
        let data = ProcessNodeData(
            turn: state.turn,
            segment: ProcessSegment(hasHeader: state.hasHeader, entries: entries)
        )
        return ChatNode(
            key: context.key,
            kind: kind,
            businessId: context.id,
            anchorSeq: anchor,
            visibility: entries.isEmpty ? .hidden : .visible,
            data: .process(data)
        )
    }

    // MARK: - 事件 → 条目

    private func apply(_ event: AssemblyEvent, contextStep: Int?, into state: inout State) {
        let seq = event.seq ?? Int(event.order)

        switch event.type {
        case "tool/call":
            let row = toolRow(from: event, seq: seq)
            // 结果先到过：并进那一行（补名字与参数），不新起一行 —— 位置留在原处。
            if let index = state.entries.firstIndex(where: { Self.callId(of: $0) == row.callId }),
               case .tool(let old) = state.entries[index] {
                state.entries[index] = .tool(Self.merge(old: old, new: row))
            } else {
                state.entries.append(.tool(row))
            }

        case "tool/result":
            let callId = event.data["message"]?["source"]?["callId"]?.string
            if let callId, let index = state.entries.firstIndex(where: { Self.callId(of: $0) == callId }),
               case .tool(let row) = state.entries[index] {
                state.entries[index] = .tool(row.settled(by: event))
            } else {
                // `tool/call` 不在窗口里 —— 用结果自带的信息出一行，工具名与参数留空。
                state.entries.append(.tool(toolRow(fromResult: event, seq: seq)))
            }

        case "assistant/message":
            for (index, block) in Self.blocks(of: event).enumerated() {
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                switch block.type {
                case "reasoning":
                    state.entries.append(.thinking(seq: seq, step: event.step, index: index,
                                                   text: block.text, time: event.time))
                case "text":
                    state.entries.append(.text(seq: seq, step: event.step, index: index,
                                               text: block.text, time: event.time))
                default:
                    break
                }
            }

        case "step/end":
            // 步号优先取位置（`step/end` 的载荷偶尔不带 `step`）；都取不到就整轮标中断 ——
            // 「这一轮不会再有结果了」比「留一行永远 running」更诚实。
            interrupt(&state, only: contextStep ?? event.step)

        case "turn/end":
            interrupt(&state, only: nil)

        default:
            break
        }
    }

    // MARK: - 物化时的过滤

    /// 滤掉「这个轮的答案」—— 它由 assistant-step 画。
    ///
    /// 按**消息**滤，不按条目：一条答案消息里可能有两个文本块，只滤最后一块会让前一块
    /// 在气泡与折叠里各出现一次。判据是「这一轮最后一步里最后一条文本所在的那条事件」，
    /// 与 `AssistantStepDefinition` 的「最后一步才画成正文」对得上。
    static func visibleEntries(_ entries: [ProcessEntry], in context: NodeContext<State>) -> [ProcessEntry] {
        // 答案 = 最后一步里**最后一条带文本的助手消息**。按「带文本」判而不是按「最后一条消息」：
        // 最后一条只有工具调用/思考时不画气泡，那时更早那句话仍是可见内容，不能被滤掉。
        guard let answer = answerOrder(in: context) else { return entries }
        // 只滤文本：同一条消息里的**思考**仍属于过程（它不在气泡里）。
        return entries.filter { entry in
            if case .text(let seq, _, _, _, _) = entry { return EventOrder(seq) != answer }
            return true
        }
    }

    /// 这一轮的答案落在哪条事件上；没有就是 `nil`。
    static func answerOrder(in context: NodeContext<State>) -> EventOrder? {
        guard let turn = (context.start?.location ?? context.matches.last?.location)?.turnLocation,
              let lastStep = turn.steps.map(\.step).max() else { return nil }
        var candidates = context.matches.filter { match in
            match.event.type == "assistant/message"
                && match.event.step == lastStep
                && Self.blocks(of: match.event).contains {
                    $0.type == "text" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
        return candidates.max { $0.event.order < $1.event.order }?.event.order
    }

    // MARK: - 工具行

    private func toolRow(from event: AssemblyEvent, seq: Int) -> ToolRow {
        ToolRow(
            callId: event.data["callId"]?.string ?? "",
            name: event.data["name"]?.string,
            summary: ToolSummary.summary(name: event.data["name"]?.string,
                                         argumentsRaw: event.data["arguments"]?.string),
            argumentsRaw: event.data["arguments"]?.string,
            resultText: nil,
            errorCode: nil,
            status: .running,
            step: event.step,
            seq: seq,
            time: event.time
        )
    }

    private func toolRow(fromResult event: AssemblyEvent, seq: Int) -> ToolRow {
        ToolRow(
            callId: event.data["message"]?["source"]?["callId"]?.string ?? "",
            name: nil,
            summary: nil,
            argumentsRaw: nil,
            resultText: nil,
            errorCode: nil,
            status: .running,
            step: event.step,
            seq: seq,
            time: event.time
        ).settled(by: event)
    }

    /// 后到的 `tool/call` 补进先到的那一行：名字与参数以它为准，结果与成败留在原地。
    private static func merge(old: ToolRow, new: ToolRow) -> ToolRow {
        ToolRow(
            callId: new.callId,
            name: new.name ?? old.name,
            summary: new.summary ?? old.summary,
            argumentsRaw: new.argumentsRaw ?? old.argumentsRaw,
            resultText: old.resultText,
            errorCode: old.errorCode,
            status: old.status,
            step: new.step ?? old.step,
            seq: old.seq,
            time: old.time
        )
    }

    /// 把「还在跑」的工具行标成中断。`only` 给定时只动那一步 ——
    /// 没有步号就整轮动，因为「这一轮关了」确实意味着全都不再落地。
    private func interrupt(_ state: inout State, only: Int?) {
        for (index, entry) in state.entries.enumerated() {
            guard case .tool(var row) = entry, row.status == .running else { continue }
            if let only, row.step != only { continue }
            row.status = .interrupted
            state.entries[index] = .tool(row)
        }
    }

    private static func callId(of entry: ProcessEntry) -> String? {
        if case .tool(let row) = entry { return row.callId }
        return nil
    }

    private struct Block {
        let type: String
        let text: String
    }

    private static func blocks(of event: AssemblyEvent) -> [Block] {
        (event.data["message"]?["content"]?.array ?? []).map { raw in
            Block(type: raw["type"]?.string ?? "", text: raw["text"]?.string ?? "")
        }
    }

    static func hidden(_ node: ChatNode) -> ChatNode {
        ChatNode(key: node.key, kind: node.kind, businessId: node.businessId,
                 anchorSeq: node.anchorSeq, visibility: .hidden, data: node.data)
    }
}

// MARK: - 工具结果的解读

private extension ToolRow {
    /// 有结果就顺带定下成败与正文。成败看 `message.isError`，错误码在 `data.error.code`。
    func settled(by result: AssemblyEvent) -> ToolRow {
        var row = self
        let message = result.data["message"]
        // v3 的载荷把 `isError` 放在 `tool-result` 块里，v4 才在 `message` 上；两处都看。
        let failed = message?["isError"]?.bool == true
            || (message?["content"]?.array ?? []).contains { $0["isError"]?.bool == true }
        row.status = failed ? .failed : .succeeded
        // 结果的正文可能套一层：`content: [{type:"tool-result", content:[{type:"text", …}]}]`。
        // 只看顶层 text 块的话，展开任何一行工具都只有参数、看不到结果。
        let text = textBlocks(in: message?["content"]).joined(separator: "\n")
        row.resultText = text.isEmpty ? nil : text
        row.errorCode = result.data["error"]?["code"]?.string
        return row
    }
}

/// 收集文本块；遇到 `tool-result` 这类容器就下钻一层（真实载荷就是这样包的）。
private func textBlocks(in content: JSONValue?) -> [String] {
    (content?.array ?? []).flatMap { block -> [String] in
        switch block["type"]?.string {
        case "text":
            return block["text"]?.string.map { [$0] } ?? []
        case "tool-result", "toolUseResult":
            return textBlocks(in: block["content"])
        default:
            return []
        }
    }
}

/// 参数摘要：从工具参数里挑一行能读的。
///
/// 参数摘要的唯一一份实现：工具行与折叠头都从这里取。
enum ToolSummary {

    /// 候选键，有序（照上游运行时列表）—— 取第一个规范化后非空的值。
    static let detailKeys = [
        "title", "description", "objective", "task", "task_name", "name",
        "question", "questions", "prompt", "message", "command", "cmd",
        "queries", "query", "pattern", "url", "uri", "file_path", "path",
        "target", "action", "status",
    ]

    /// 摘要的上限，按字符（= 扩展字素簇）算，与上游的 grapheme 分段同一口径。
    static let detailMaxCharacters = 160

    /// 从参数里挑一行摘要；一个候选键都没命中时回落到工具名，不显示成空。
    static func summary(name: String?, argumentsRaw: String?) -> String? {
        if let raw = argumentsRaw,
           let data = raw.data(using: .utf8),
           let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object {
            for key in detailKeys {
                let detail = key == "questions"
                    ? firstQuestion(in: object[key])
                    : normalizeDetail(object[key])
                if !detail.isEmpty { return detail }
            }
        }
        guard let name else { return nil }
        let fallback = normalizeDetail(name)
        return fallback.isEmpty ? nil : fallback
    }

    /// `questions` 是唯一一个「值是对象数组」的候选键：取第一个问题。
    static func firstQuestion(in value: JSONValue?) -> String {
        for item in value?.array ?? [] {
            let detail = normalizeDetail(item["question"])
            if !detail.isEmpty { return detail }
        }
        return ""
    }

    static func normalizeDetail(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text):
            return normalizeDetail(text)
        case .array(let items):
            // 只有「字符串数组」才可读（如 queries）；混着别的就当没有。
            let strings = items.compactMap(\.string)
            guard strings.count == items.count, !strings.isEmpty else { return "" }
            return normalizeDetail(strings.joined(separator: ", "))
        default:
            return ""
        }
    }

    /// 空白折叠成单空格后截断。按**字素**数截，不是 UTF-8 字节 —— 
    /// 否则中文与 emoji 会被切成半个字符。
    static func normalizeDetail(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > detailMaxCharacters else { return collapsed }
        var head = String(collapsed.prefix(detailMaxCharacters - 1))
        while head.hasSuffix(" ") { head.removeLast() }
        return head + "…"
    }
}
