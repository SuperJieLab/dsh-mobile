/**
 * 会话详情组装器 —— 事件窗口 → 显示节点。
 *
 * 它不碰网络、不碰 UI、不碰磁盘：输入是一段事件（镜像里本来就有全量的原始事件），
 * 输出是「这一屏要画什么」。把它单独拿出来，是因为**配对与分组是最容易错的一环**
 * ——工具调用跨两条事件、轮次边界要收口悬挂的调用、窗口边界会切出半截形态——
 * 而这些判断一旦缠进 SwiftUI 视图就没法单独验。分开之后，它既能被 iOS target 编，
 * 也能被 `swiftc` 编成 macOS 命令行程序跑断言（`ios/tests/run-assembler.sh`）。
 *
 * ## 三种输入，一条输出轴
 *
 * 事件窗口进来，出去的是**有序**的节点：用户消息、一轮的过程、一轮的最终答案。
 * 顺序永远等于事件顺序 —— 中间的思考块与工具调用不按类型分组，否则「思考 → 工具
 * → 思考 → 工具」这种交替会串位。
 *
 * ## 判定的出处
 *
 * 配对与状态判定照**运行时产物**（`@deepseek-ai/dsh-client-ui-chat`，经
 * `~/.npm/_npx/<hash>/node_modules/` 实读），不是照仓库源码 —— 两者在 `isError` 的
 * 读法上已经不一致过一次：
 *
 * - 配对键：`tool/call.data.callId` ↔ `tool/result.data.message.source.callId`
 * - 成败：`tool/result.data.message.isError`（在 `message` 上，不在 `content[0]`）
 * - 中断：所在 step / turn 已关闭而这条 call 一直没有结果
 * - 「最终答案」：该轮**最后一个 step** 的助手消息，且它含真正的回复内容、不含工具调用块
 *
 * 上游那套「事件 → 节点」的注册表不复用、也不照搬：它是给可插拔前端用的扩展面，
 * 这里只需要它的语义（配对、分组、退化）。出处见
 * `docs/dev/plans/M6-presentation-layer.md` §3.2 决定 8–14。
 */

import Foundation

// MARK: - 显示节点

/// 会话详情里的一条显示节点。
enum TranscriptNode: Equatable {
    /// 一条对话消息：用户发言，或一轮的最终答案。
    case message(DisplayMessage)
    /// 一轮的过程：思考、工具调用、中间文本，按事件顺序。
    case process(NodeProcess)
}

extension TranscriptNode: Identifiable {
    /// 列表里的身份。取**这一组首个过程**的身份，而不是在节点数组里的序号 ——
    /// 往回翻是往前面插内容，序号会整体错位，屏上的行就会被全部重挂载。
    ///
    /// ⚠️ 这条保证的**适用范围**（真机日志切片实跑核过）：前插只落在一处 —— 窗口
    /// 头部那一组。其余各组的 `turn/start` 都在窗口里，前插的内容排在它们之前，
    /// 碰不到它们，所以身份逐条不变。头部那一组本身会被前插改（见 `ProcessEntry`），
    /// 而它由「无头」变「有头」时形态本来就变了，重挂载一次没有状态可丢 ——
    /// 无头组不可展开（`TurnProcessRow` 的 `hasHeader` 分支）。
    var id: String {
        switch self {
        case .message(let message):
            return "message-\(message.seq)"
        case .process(let process):
            switch process.entries.first {
            case .thinking(let seq, _, _): return "process-\(seq)"
            case .text(let seq, _, _): return "process-\(seq)"
            case .tool(let row): return "process-\(row.seq)"
            case nil: return "process-turn-\(process.turn ?? -1)"
            }
        }
    }
}

/// 一轮的过程。默认收起，展开后逐行呈现。
struct NodeProcess: Equatable {
    /// 这一轮的编号。`nil` = 连编号都取不到。
    let turn: Int?
    /// 这一组的开头（`turn/start`）在不在窗口里 —— 不在就不画折叠头。
    ///
    /// 窗口边界会把一轮切掉半截：那时过程仍要如实显示（不丢行），但它缺了开头，
    /// 画一个「本轮摘要」等于假装这一轮完整（§3.2 决定 11、判据 A7）。
    let hasHeader: Bool
    let entries: [ProcessEntry]

    /// 折叠头上的一句话；没有可说的就是 `nil`。
    ///
    /// 两组计数、**只写非零的那些** —— 只有工具调用时不写成「2 次工具调用 · 0 条消息」
    /// （零是噪音，不是信息）。两个数都是 0 而这轮确实有过程（只想了没做）时，
    /// 用兜底文案而不是「0 次工具调用」。文案照上游 locale
    /// （`message.turnProcess.toolCalls` / `.messages` / `.thoughtForAWhile` / `.separator`）。
    var summary: String? {
        var toolCalls = 0
        var midMessages = 0
        var hasThinking = false
        for entry in entries {
            switch entry {
            case .tool: toolCalls += 1
            case .text: midMessages += 1
            case .thinking: hasThinking = true
            }
        }

        var parts: [String] = []
        if toolCalls > 0 { parts.append("\(toolCalls) 次工具调用") }
        if midMessages > 0 { parts.append("\(midMessages) 条消息") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return hasThinking ? "已思考" : nil
    }
}

/// 过程里的一行。
enum ProcessEntry: Equatable {
    /// 一段思考（`reasoning` 块）。它进过程、不进正文（§3.2 决定 13）。
    case thinking(seq: Int, text: String, time: Double)
    /// 一次工具调用。
    case tool(ToolRow)
    /// 一轮中间的助手文本（不是最终答案的那部分）。
    case text(seq: Int, text: String, time: Double)
}

extension ProcessEntry: Identifiable {
    /// 这一行的身份。取**事件 seq**，不取它在组内的偏移 —— 往回翻会往窗口头部那一组里
    /// 插入更早的行，偏移会整体挪位（行被重挂载，展开的工具行与思考会自己收回去），
    /// seq 不会。理由与节点身份同一条。
    ///
    /// 前缀带上种类：同一条助手消息能同时产出「思考」与「文本」两行，两行的 seq 相同。
    /// 带上种类才在组内唯一（`tool` 那行只可能来自它自己那条事件）。
    var id: String {
        switch self {
        case .thinking(let seq, _, _): return "thinking-\(seq)"
        case .text(let seq, _, _): return "text-\(seq)"
        case .tool(let row): return "tool-\(row.seq)"
        }
    }
}

/// 一次工具调用的显示行。
///
/// 四种状态齐全，半截配对如实退化、不猜（§3.2 决定 11）：
/// 有结果且 `isError` 假 → 成功；真 → 失败；只有调用 → 运行中；
/// 轮次关闭而始终没有结果 → 中断。
struct ToolRow: Equatable {

    enum Status: Equatable {
        case running
        case succeeded
        case failed
        /// 轮次 / 步骤已关闭，这条调用一直没有结果 —— 上游把它合成为一条
        /// `error.code = 'interrupted'` 的失败结果，这里保留成一个独立状态，
        /// 因为它要说的不是「工具失败」，是「我们不知道它怎么了」。
        case interrupted
    }

    /// 配对键。`tool/call` 与 `tool/result` 靠它认亲。
    let callId: String
    /// 工具名。`nil` = `tool/call` 不在窗口里（只看到结果）—— 不编一个。
    let name: String?
    /// 一行摘要，从参数里按候选键挑（见 `summary`）。同样可以是「不知道」。
    let summary: String?
    /// 模型给的原始参数（原样 JSON 文本），展开时看。
    let argumentsRaw: String?
    /// 工具返回的正文，展开时看。
    fileprivate(set) var resultText: String?
    /// 失败时上游给的错误码（`data.error.code`）。
    fileprivate(set) var errorCode: String?
    fileprivate(set) var status: Status
    /// 所在步骤号 —— 判「中断」时要看它关没关。
    let step: Int?
    /// 这一行的身份：`tool/call` 的 `seq`；只有结果时是 `tool/result` 的 `seq`。
    let seq: Int
    let time: Double
}

// MARK: - 组装器

/// 把一段事件组装成显示节点。**纯状态机**：不 import SwiftUI / UIKit。
///
/// 唯一的状态是「已经上报过哪些不认识的类型」—— 按类型去重，让每次打开会话
/// 重放整段窗口时只留一条痕。
struct TranscriptAssembler {

    /// 组装结果里出现不认识的 `type` 时调一次（按类型去重）。上游加新事件类型时，
    /// 会话照常显示，而日志里留下线索（§3.2 决定 14）。
    private let onUnknownEventType: ((String) -> Void)?
    private var reportedUnknownTypes: Set<String> = []

    init(onUnknownEventType: ((String) -> Void)? = nil) {
        self.onUnknownEventType = onUnknownEventType
    }

    /// 组装一段事件（按 `seq` 升序、连续）。可以反复调用；每次只处理给进来的这段。
    mutating func assemble(_ events: [SessionEvent]) -> [TranscriptNode] {
        let answers = Self.answerSeqs(in: events)
        var nodes: [TranscriptNode] = []
        var draft: ProcessDraft?

        /// 收口：把攒下的过程行变成节点（空的不产生节点）。
        ///
        /// - Parameter endingTurn: 这一轮是不是就此结束。**用户消息夹在 `turn/start`
        ///   与助手的首个输出之间是常态**，那时过程要收口（否则用户那句会排到过程后面，
        ///   顺序就错了），但这一轮并没有结束 —— 所以「有头」这个身份得留着。
        ///   真机实测过：把它一起清掉的话，窗口里 13 个 `turn/start` 全被判成无头。
        func flush(endingTurn: Bool = false) {
            if let current = draft, !current.entries.isEmpty {
                nodes.append(.process(NodeProcess(turn: current.turn, hasHeader: current.hasHeader, entries: current.entries)))
                draft?.entries = []
            }
            if endingTurn { draft = nil }
        }

        /// 确保有一个可写的草稿。事件里带的 `turn` 是**真实的轮次号**，但这一组的
        /// 开头不在窗口里 —— 所以它是「无头」的（不画折叠头）。
        func open(turn: Int?) {
            if draft == nil { draft = ProcessDraft(turn: turn, hasHeader: false) }
        }

        /// 把一个范围内的「运行中」标成「中断」。
        func interrupt(step: Int?) {
            guard var current = draft else { return }
            for (index, entry) in current.entries.enumerated() {
                guard case .tool(var row) = entry, row.status == .running else { continue }
                if let step, row.step != step { continue }
                row.status = .interrupted
                current.entries[index] = .tool(row)
            }
            draft = current
        }

        for event in events {
            switch event.type {

            case "user/message":
                flush()
                // 复用协议层已有的解码：它已经处理过「插件注入的上下文不算人打的字」。
                if let message = event.displayMessage { nodes.append(.message(message)) }

            case "turn/start":
                // 一轮从这里开始 —— 这一组是「有头」的。
                flush(endingTurn: true)
                draft = ProcessDraft(turn: event.data["turn"]?.int, hasHeader: true)

            case "turn/end":
                // 轮次关闭 ⇒ 这一轮里还没落地的调用再也不会落地了。
                interrupt(step: nil)
                flush(endingTurn: true)

            case "step/end":
                interrupt(step: event.data["step"]?.int)

            case "step/start":
                // 步骤边界不单独出节点 —— 它是轮次内部的节奏，不是给人看的内容。
                break

            case "tool/call":
                open(turn: event.data["turn"]?.int)
                draft?.entries.append(.tool(Self.toolRow(from: event)))

            case "tool/result":
                open(turn: event.data["turn"]?.int)
                let callId = event.data["message"]?["source"]?["callId"]?.string
                if let callId, let index = draft?.entries.firstIndex(where: { Self.callId(of: $0) == callId }) {
                    // 配对上了：把结果补进那一行，保留原来的参数（不假装重新知道）。
                    if case .tool(let row) = draft?.entries[index] {
                        draft?.entries[index] = .tool(Self.toolRow(row, settledBy: event))
                    }
                } else {
                    // `tool/call` 不在窗口里（往回翻的边界）—— 用结果自带的信息出一行，
                    // 参数与工具名都留空，不假装有。
                    draft?.entries.append(.tool(Self.toolRow(fromResult: event)))
                }

            case "assistant/message":
                let blocks = Self.blocks(of: event)
                // 思考先入过程。事件内的块顺序就是显示顺序，交替场景下不会串位。
                for block in blocks where block.type == "reasoning" {
                    guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    open(turn: event.data["turn"]?.int)
                    draft?.entries.append(.thinking(seq: event.seq, text: block.text, time: event.time))
                }
                if answers.contains(event.seq) {
                    // 最终答案不在折叠里：先把已攒的过程收口，答案单独成节点。
                    let text = blocks.filter { $0.type == "text" }.map(\.text).joined(separator: "\n")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                    flush()
                    nodes.append(.message(DisplayMessage(seq: event.seq, role: .assistant, text: text, time: event.time)))
                } else {
                    for block in blocks where block.type == "text" {
                        guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        open(turn: event.data["turn"]?.int)
                        draft?.entries.append(.text(seq: event.seq, text: block.text, time: event.time))
                    }
                }

            default:
                // 不认识的新类型：跳过，已组装的节点不受影响；留一条痕，按类型去重。
                if !Self.consumedTypes.contains(event.type), !Self.isKnownBypass(event.type) {
                    if reportedUnknownTypes.insert(event.type).inserted {
                        onUnknownEventType?(event.type)
                    }
                }
            }
        }

        flush()
        return nodes
    }

    /// 组装过程中攒下的一轮内容。
    private struct ProcessDraft {
        let turn: Int?
        /// 见过 `turn/start` 吗 —— 决定这一组画不画折叠头。
        let hasHeader: Bool
        var entries: [ProcessEntry] = []
    }
}

// MARK: - 事件解读

private extension TranscriptAssembler {

    struct Block {
        let type: String
        let text: String
    }

    static func blocks(of event: SessionEvent) -> [Block] {
        (event.data["message"]?["content"]?.array ?? []).map { raw in
            Block(type: raw["type"]?.string ?? "", text: raw["text"]?.string ?? "")
        }
    }

    /// 每个 `turn` 的「最终答案」事件 seq。
    ///
    /// 照上游 `latestAnswer`，两步：
    /// 1. 先定这一轮的**最后一个 step** —— 由 `step/start` 与助手消息共同界定，
    ///    因为一个 step 存不存在不取决于它有没有产出一条消息；
    /// 2. 再在那个 step 里找助手消息，它必须（a）含真正的回复内容、
    ///    （b）不含工具调用块。
    ///
    /// 两步缺一不可：只做第 2 步的话，「最后一步开了头就出事」的轮次会拿前面
    /// step 说过的话冒充最终回答 —— 那是**编出来一条回答**，比不显示更坏。
    static func answerSeqs(in events: [SessionEvent]) -> Set<Int> {
        var lastStep: [Int: Int] = [:]
        for event in events {
            switch event.type {
            case "step/start", "assistant/message":
                let turn = event.data["turn"]?.int ?? 0
                lastStep[turn] = max(lastStep[turn] ?? -1, event.data["step"]?.int ?? 0)
            default:
                break
            }
        }

        var candidates: [Int: (seq: Int, blocks: [Block])] = [:]
        for event in events where event.type == "assistant/message" {
            let turn = event.data["turn"]?.int ?? 0
            guard event.data["step"]?.int == lastStep[turn] else { continue }
            // 同一个 step 里的多条消息：后到的那条才是这一步的定论。
            if let current = candidates[turn], current.seq > event.seq { continue }
            candidates[turn] = (event.seq, blocks(of: event))
        }

        var answers: Set<Int> = []
        for (_, candidate) in candidates {
            if candidate.blocks.contains(where: { $0.type == "tool-call" }) { continue }
            if hasReplyContent(candidate.blocks) { answers.insert(candidate.seq) }
        }
        return answers
    }

    /// 上游 `hasAssistantReplyContent`：除思考与工具调用之外的块才算「回复内容」；
    /// 文本块还要非空白（一条只写了几个空格的消息不是回答）。
    static func hasReplyContent(_ blocks: [Block]) -> Bool {
        blocks.contains { block in
            if block.type == "reasoning" || block.type == "tool-call" { return false }
            if block.type == "text" {
                return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    /// 从一个 `tool/call` 建一行（还没有结果）。
    static func toolRow(from event: SessionEvent) -> ToolRow {
        let data = event.data
        return toolRow(
            callId: data["callId"]?.string ?? "",
            name: data["name"]?.string,
            argumentsRaw: data["arguments"]?.string,
            step: data["step"]?.int,
            seq: event.seq,
            time: event.time,
            result: nil
        )
    }

    /// 把结果补进已有的那一行 —— 参数与工具名沿用 `tool/call` 给的，不从结果里猜。
    static func toolRow(_ row: ToolRow, settledBy result: SessionEvent) -> ToolRow {
        toolRow(
            callId: row.callId,
            name: row.name,
            argumentsRaw: row.argumentsRaw,
            step: row.step,
            seq: row.seq,
            time: row.time,
            result: result
        )
    }

    /// 只看见结果（`tool/call` 在窗口外）：出一行，但工具名与参数都留空。
    static func toolRow(fromResult event: SessionEvent) -> ToolRow {
        toolRow(
            callId: event.data["message"]?["source"]?["callId"]?.string ?? "",
            name: nil,
            argumentsRaw: nil,
            step: event.data["step"]?.int,
            seq: event.seq,
            time: event.time,
            result: event
        )
    }

    /// 工具行的唯一构造口 —— 有结果就顺带定下成败与正文。
    static func toolRow(
        callId: String,
        name: String?,
        argumentsRaw: String?,
        step: Int?,
        seq: Int,
        time: Double,
        result: SessionEvent?
    ) -> ToolRow {
        var status: ToolRow.Status = .running
        var resultText: String?
        var errorCode: String?

        if let result {
            let message = result.data["message"]
            let failed = message?["isError"]?.bool == true
            status = failed ? .failed : .succeeded
            // 结果的正文是块数组；一期只呈现文本块（图片等其它块登记在 §1.3）。
            let text = (message?["content"]?.array ?? []).compactMap { block -> String? in
                guard block["type"]?.string == "text" else { return nil }
                return block["text"]?.string
            }.joined(separator: "\n")
            resultText = text.isEmpty ? nil : text
            errorCode = result.data["error"]?["code"]?.string
        }

        return ToolRow(
            callId: callId,
            name: name,
            summary: Self.summary(name: name, argumentsRaw: argumentsRaw),
            argumentsRaw: argumentsRaw,
            resultText: resultText,
            errorCode: errorCode,
            status: status,
            step: step,
            seq: seq,
            time: time
        )
    }

    static func callId(of entry: ProcessEntry) -> String? {
        if case .tool(let row) = entry { return row.callId }
        return nil
    }

    // MARK: 参数摘要

    /// 候选键，**有序** —— 照上游运行时的列表取第一个规范化后非空的值。
    /// 顺序本身就是规则：`description` 比 `command` 更可读，所以它排在前面。
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

    /// 空白折叠成单空格后截断。截断位置按**字素**数，不是 UTF-8 字节 ——
    /// 否则中文与 emoji 会被切成半个字符。
    static func normalizeDetail(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > detailMaxCharacters else { return collapsed }
        var head = String(collapsed.prefix(detailMaxCharacters - 1))
        while head.hasSuffix(" ") { head.removeLast() }
        return head + "…"
    }

    // MARK: 事件类型的认识范围

    /// 组装器自己消费的类型。
    static let consumedTypes: Set<String> = [
        "user/message", "assistant/message",
        "turn/start", "turn/end", "step/start", "step/end",
        "tool/call", "tool/result",
    ]

    /// 会话日志里必然出现、但归别的链路管的事件类型前缀（审批、投影、沙箱、
    /// 子代理、用量…）。
    ///
    /// 这不是「支持的清单」，是**降噪的清单** —— 没有它，「不认识就上报」会把
    /// 每次打开会话都变成一片噪音，真正该看见的那条新类型反而被埋了。
    static let knownBypassPrefixes = [
        "approval/", "session/", "session-log", "request/", "agent/",
        "web/", "sandbox/", "permission/", "system/", "assistant/",
        "turn/", "step/", "deliverable/",
    ]

    static func isKnownBypass(_ type: String) -> Bool {
        knownBypassPrefixes.contains { type.hasPrefix($0) }
    }
}
