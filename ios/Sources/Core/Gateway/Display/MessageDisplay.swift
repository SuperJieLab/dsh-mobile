/**
 * 哪些事件能变成一条消息、取哪个文本块 —— 显示取舍，不是协议规则。
 *
 * 原注释里就写着「两条显示规则（都是显示决策，不是协议规则）」，R18 期1 把它搬到与那句话
 * 相符的目录。`DisplayMessage` 与 `Role` 是显示投影，不是线上形状，一并搬来。
 *
 * 消费者：`SessionSync`（`mirror.events.compactMap(\.displayMessage)`）、
 * `TranscriptAssembler`（逐条事件取值）。
 */
import Foundation

// MARK: - 从事件里抽出可显示的消息

/// 屏幕上显示的一条消息气泡。
struct DisplayMessage: Hashable {
    enum Role: Hashable {
        case user
        case assistant
    }

    let seq: Int
    let role: Role
    let text: String
    let time: Double
}

extension SessionEvent {
    /// 把一条事件变成一条可显示的消息；变不出来就是 `nil`。
    ///
    /// ⚠️ **两种事件的消息不是一个形状**：
    /// - `user/message` —— 消息对象直接在 `data` 上：`data.content` / `data.role` / `data.source`
    /// - `assistant/message` —— 消息包在 `data.message` 里，与 `data.usage` / `data.stream` 并列
    ///
    /// 当成对称处理，症状是**用户消息被静默吞掉**。两条显示规则（都是显示决策，不是协议规则）：
    /// - 只取 `text` 块（`reasoning` 与 `tool-call` 属于过程，不属于对话内容）；`user/message` 只认
    ///   `source.kind == "user"` —— 插件注入的运行时上下文也走这个事件类型
    ///   （`kind == "plugin"`，整段
    ///   沙箱与审批策略），不是人打的字，不该进对话流。
    var displayMessage: DisplayMessage? {
        switch type {
        case "user/message":
            guard data["source"]?["kind"]?.string == "user" else { return nil }
            guard let text = Self.joinedText(in: data["content"]) else { return nil }
            return DisplayMessage(seq: seq, role: .user, text: text, time: time)

        case "assistant/message":
            guard let text = Self.joinedText(in: data["message"]?["content"]) else { return nil }
            return DisplayMessage(seq: seq, role: .assistant, text: text, time: time)

        default:
            return nil
        }
    }

    /// 把一个内容块数组里的 `text` 块拼起来；一个 `text` 块都没有就是 `nil`。
    private static func joinedText(in blocks: JSONValue?) -> String? {
        let parts = (blocks?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
