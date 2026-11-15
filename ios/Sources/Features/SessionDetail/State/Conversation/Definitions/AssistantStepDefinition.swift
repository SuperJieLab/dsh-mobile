/**
 * 一步的助手输出 —— 一个槽位从「正在输出」活到「定稿」，身份不变。
 *
 * 身份是 `turn:step` 而不是某条事件的 `seq`：`step/start` 一到这个坐标就存在了，
 * 而它比第一段文字还早。流式增量与持久定稿都往同一个格子写，所以定稿只是换内容，不是换节点。
 *
 * 一段文字由谁画：**一轮里最后一步的定稿文本**是「答案」，由这个节点画出来；
 * 其余文本属于过程，归 `ProcessDefinition`。这条分工是本期自造的（上游用 Group 解决），
 * 两边共用一个判据：答案 = 最后一步里**最后一条带文本的助手消息**。
 */
import Foundation

enum AssistantBlock: Equatable {
    case text(String)
    case reasoning(String)
    case toolCall(callId: String, name: String?)
}

struct AssistantNodeData: Equatable {
    enum Status: Equatable {
        case running
        case settled
        /// 轮次关上了而输出没有定稿 —— 上游把它合成为一条 interrupted 结果。
        case interrupted
    }

    let status: Status
    let turn: Int
    let step: Int
    let text: String
    let blocks: [AssistantBlock]
    let time: Double
}

struct AssistantStepDefinition: ConversationNodeDefinition {

    struct State: Equatable {
        var turn: Int
        var step: Int
        /// 按块下标累积：同一段文字的 `text-delta` 要拼进同一块，不能每帧新建一块。
        var blocks: [Int: AssistantBlock] = [:]
        var firstVisibleOrder: EventOrder?
        var firstVisibleTime: Double?
        /// 定稿的时间与内容。`nil` = 还没定稿。
        var settledOrder: EventOrder?
        var settledTime: Double?
        var settledBlocks: [AssistantBlock]?
        var interrupted = false
    }

    let kind = "assistant-step"

    func match(_ event: AssemblyEvent) -> MatchResult? {
        switch event.type {
        case "step/start":
            guard let turn = event.turn, let step = event.step else { return nil }
            return MatchResult(id: "\(turn):\(step)", role: .start)

        case "assistant/live-chunk":
            guard let turn = event.turn, let step = event.step else { return nil }
            return MatchResult(id: "\(turn):\(step)", role: .update)

        case "assistant/message", "assistant/attempt":
            // 替换型（压缩点）不是「这一步的输出」，它是另一条产线的产物。
            guard !event.isReplacement else { return nil }
            guard let turn = event.turn, let step = event.step else { return nil }
            return MatchResult(id: "\(turn):\(step)", role: .update)

        case "llm/retry":
            guard let turn = event.turn, let step = event.step else { return nil }
            return MatchResult(id: "\(turn):\(step)", role: .update)

        default:
            return nil
        }
    }

    func start(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        guard let turn = match.event.turn, let step = match.event.step else {
            assertionFailure("assistant-step start requires turn/step")
            return State(turn: -1, step: -1)
        }
        return State(turn: turn, step: step)
    }

    func update(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        guard var state = context.state else { return start(context, match) }
        switch match.event.type {
        case "assistant/live-chunk":
            guard let chunk = match.event.data["chunk"] else { return state }
            Self.apply(chunk: chunk, order: match.event.order, time: match.event.time, to: &state)

        case "assistant/message":
            let blocks = Self.blocks(in: match.event.data["message"]?["content"])
            let interrupted = match.event.data["interrupted"]?.bool == true
            // 只让**带文本**的消息接管气泡：过程侧按「最后一条带文本的消息」滤答案，
            // 两边必须是同一份判据，否则那条文本两处都不画。
            if interrupted || Self.hasReplyText(blocks) {
                state.settledBlocks = blocks
                state.settledOrder = match.event.order
                state.settledTime = match.event.time
            }
            state.interrupted = interrupted

        case "assistant/attempt":
            // 失败的 attempt 以紧凑流补交：用户已经看见的半句话要留下，标成中断。
            for record in CompactStream.expand(match.event.data["stream"]?.array ?? []) {
                Self.apply(chunk: record.chunk, order: match.event.order, time: record.time, to: &state)
            }
            state.interrupted = true

        case "llm/retry":
            Self.resetForRetry(&state)

        default:
            break
        }
        return state
    }

    func publication(_ match: ConversationMatch) -> Publication {
        guard match.event.type == "assistant/live-chunk" else { return .immediate }
        switch match.event.data["chunk"]?["type"]?.string {
        case "usage", "finish": return .none
        default: return .animationFrame
        }
    }

    func buildViewNode(_ context: NodeContext<State>) -> ChatNode? {
        // 窗口首条就是 `assistant/message`（往回翻的切点落在它上面）时，这一步没有 `step/start`，
        // 引擎建不出 state。按已收到的命中重放一遍 —— 不这样做，这段回答在屏上完全不存在。
        guard let state = context.state ?? Self.fallbackState(context) else {
            return context.current.map(Self.hidden)
        }
        let blocks = state.settledBlocks ?? Self.ordered(state.blocks)
        let visible = blocks.contains { Self.isVisible($0) }
        // 从没有过可见内容、也没有物化过节点 ⇒ 不出节点。一旦出过，就只能转 hidden。
        if !visible, context.current == nil { return nil }

        let anchor = state.settledOrder
            ?? state.firstVisibleOrder
            ?? context.start?.event.order
            ?? context.matches.first?.event.order
            ?? 0
        let time = state.settledTime ?? state.firstVisibleTime ?? context.start?.event.time ?? 0
        // 一轮关上了而这一步没有定稿：输出是被截断的，不是还在跑。
        let cutOff = state.settledOrder == nil && context.start?.location.closedBoundary != nil
        let status: AssistantNodeData.Status = state.interrupted || cutOff
            ? .interrupted
            : (state.settledOrder == nil ? .running : .settled)

        // 只有最后一步画成正文；中间步的文本进过程段。
        // 「有正文」指有**回复文本**：只有思考没有文本时不出气泡，否则会得到一个空壳。
        let text = Self.text(of: blocks)
        let isAnswer = (visible && !text.isEmpty) && Self.isLastStep(context, step: state.step)
        let data = AssistantNodeData(
            status: status,
            turn: state.turn,
            step: state.step,
            text: text,
            blocks: blocks,
            time: time
        )
        return ChatNode(
            key: context.key,
            kind: kind,
            businessId: context.id,
            anchorSeq: anchor,
            visibility: isAnswer ? .visible : .hidden,
            data: .assistant(data)
        )
    }

    /// 重试把这一步的可见内容整份退掉，重新输出 —— 坐标不变、内容重来。
    /// 正式路径与回放共用这一份，避免两处各写一遍后漂开。
    private static func resetForRetry(_ state: inout State) {
        state.blocks = [:]
        state.firstVisibleOrder = nil
        state.firstVisibleTime = nil
        state.settledBlocks = nil
        state.settledOrder = nil
        state.interrupted = false
    }

    // MARK: - 回放

    /// 没有 start 的格子：按命中顺序自己攒一份状态。照上游同名函数 ——
    /// 它认的输出与正式路径完全一样（live-chunk 累积、定稿替换、重试清空）。
    static func fallbackState(_ context: NodeContext<State>) -> State? {
        var state: State?
        for match in context.matches {
            let event = match.event
            switch event.type {
            case "assistant/live-chunk":
                state = state ?? State(turn: event.turn ?? -1, step: event.step ?? -1)
                if let chunk = event.data["chunk"] {
                    Self.apply(chunk: chunk, order: event.order, time: event.time, to: &state!)
                }
            case "assistant/message":
                state = state ?? State(turn: event.turn ?? -1, step: event.step ?? -1)
                state?.settledBlocks = Self.blocks(in: event.data["message"]?["content"])
                state?.settledOrder = event.order
                state?.settledTime = event.time
                state?.interrupted = event.data["interrupted"]?.bool == true
            case "assistant/attempt":
                state = state ?? State(turn: event.turn ?? -1, step: event.step ?? -1)
                for record in CompactStream.expand(event.data["stream"]?.array ?? []) {
                    Self.apply(chunk: record.chunk, order: event.order, time: record.time, to: &state!)
                }
                state?.interrupted = true
            case "llm/retry":
                if state != nil { Self.resetForRetry(&state!) }
            default:
                break
            }
        }
        return state
    }

    // MARK: - 事件解读

    private static func apply(chunk: JSONValue, order: EventOrder, time: Double, to state: inout State) {
        let index = chunk["index"]?.int ?? 0
        switch chunk["type"]?.string {
        case "text-delta":
            state.blocks[index] = .text(Self.text(of: state.blocks[index]) + (chunk["text"]?.string ?? ""))
        case "reasoning-delta":
            state.blocks[index] = .reasoning(Self.text(of: state.blocks[index]) + (chunk["text"]?.string ?? ""))
        case "tool-call-delta":
            state.blocks[index] = .toolCall(
                callId: chunk["id"]?.string ?? Self.callId(of: state.blocks[index]) ?? "",
                name: chunk["name"]?.string ?? Self.name(of: state.blocks[index])
            )
        case "block-end":
            let block = chunk["block"]
            state.blocks[index] = Self.block(from: block)
        default:
            return
        }
        if state.firstVisibleOrder == nil, state.blocks[index].map(Self.isVisible) == true {
            state.firstVisibleOrder = order
            state.firstVisibleTime = time
        }
    }

    /// 这一步是它所在轮次的最后一步吗 —— 决定它是「答案」还是「过程里的一段」。
    static func isLastStep(_ context: NodeContext<State>, step: Int) -> Bool {
        // 没有 start 的格子（窗口首条就是定稿）也要能判：取命中里的位置，而不是只看 start。
        guard let turn = (context.start?.location ?? context.matches.last?.location)?.turnLocation else {
            return false
        }
        guard let maximum = turn.steps.map(\.step).max() else { return false }
        // 用传进来的 step，不读 `context.state`：回放出来的状态不在 context 里。
        return step == maximum
    }

    static func blocks(in content: JSONValue?) -> [AssistantBlock] {
        (content?.array ?? []).compactMap { raw in
            guard raw.isNotNil else { return nil }
            return block(from: raw)
        }
    }

    static func block(from raw: JSONValue?) -> AssistantBlock? {
        switch raw?["type"]?.string {
        case "text": return .text(raw?["text"]?.string ?? "")
        case "reasoning": return .reasoning(raw?["text"]?.string ?? "")
        case "tool-call":
            return .toolCall(callId: raw?["callId"]?.string ?? "", name: raw?["name"]?.string)
        default: return nil
        }
    }

    /// 有没有**回复文本**（不算思考、不算工具调用）。
    /// 与过程侧判定答案的那一份是同一件事：只让带文本的消息接管气泡，否则那条文本两处都不画。
    static func hasReplyText(_ blocks: [AssistantBlock]) -> Bool {
        blocks.contains { block in
            guard case .text(let text) = block else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func isVisible(_ block: AssistantBlock) -> Bool {
        switch block {
        case .text(let text), .reasoning(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .toolCall:
            return false
        }
    }

    static func text(of block: AssistantBlock?) -> String {
        switch block {
        case .text(let text), .reasoning(let text): return text
        default: return ""
        }
    }

    static func text(of blocks: [AssistantBlock]) -> String {
        blocks.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func callId(of block: AssistantBlock?) -> String? {
        if case .toolCall(let callId, _) = block { return callId }
        return nil
    }

    static func name(of block: AssistantBlock?) -> String? {
        if case .toolCall(_, let name) = block { return name }
        return nil
    }

    static func ordered(_ blocks: [Int: AssistantBlock]) -> [AssistantBlock] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    static func hidden(_ node: ChatNode) -> ChatNode {
        ChatNode(key: node.key, kind: node.kind, businessId: node.businessId,
                 anchorSeq: node.anchorSeq, visibility: .hidden, data: node.data)
    }
}

private extension JSONValue {
    /// `null` 与「字段缺席」都算没有 —— 内容块里不会出现有意义的 null。
    var isNotNil: Bool { self != .null }
}
