/**
 * 哪些事件能变成一条消息、取哪个文本块 —— 显示取舍，不是协议规则。
 *
 * 它是判定而不是文案：读 `JSONValue`、按事件类型分支、可能给不出消息，与 `SessionMirror`
 * 同源（都随上游事件形状变）。`DisplayMessage` 与 `Role` 是它的输出形状，不是线上形状 ——
 * 协议给的是事件体，这两个类型是为「画一条气泡」折叠出来的，随判定同处。
 *
 * 消费者：`SessionSync`（`mirror.events.compactMap(\.displayMessage)`）、
 * `TranscriptAssembler`（逐条事件取值）、`SessionDetailView`（拿 `DisplayMessage` 画气泡）。
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

    /// 一次命令的生命周期。上游把它记成两条配对事件（`command/run` 与 `command/done`，
    /// 由 `commandId` 关联），两者都是 **log-only**：不进模型 transcript，但进会话日志 ——
    /// 所以手机能从订阅流里看到「按了什么、结果如何」。
    ///
    /// 与 `displayMessage` 分开：命令不是对话消息（不该套气泡、不该被当作某人的发言），
    /// 它的展示形状是「一行命令 + 结果」。判定仍住这里，理由同 `displayMessage` ——
    /// 它随上游事件形状变。
    var commandLifecycle: CommandLifecycle? {
        switch type {
        case "command/run":
            guard let commandId = data["commandId"]?.string,
                  let name = data["name"]?.string else { return nil }
            return .started(commandId: commandId, name: name, args: data["args"]?.string)

        case "command/done":
            guard let commandId = data["commandId"]?.string,
                  let kind = data["kind"]?.string else { return nil }
            let text = data["text"]?.string
            // 只有上游明说 success 才算成功；别的取值（含将来新增的）一律按失败显示，
            // 因为「以为成功了其实没有」比「以为失败其实成功」代价大。
            return .settled(commandId: commandId, outcome: kind == "success" ? .success(text) : .failure(text))

        default:
            return nil
        }
    }
}

/// 命令生命周期的一条事件。
enum CommandLifecycle: Equatable {
    /// `command/run`：命令进入了 handler。
    case started(commandId: String, name: String, args: String?)
    /// `command/done`：配对的结局。
    case settled(commandId: String, outcome: CommandOutcome)
}

/// 一次命令执行的结局。
enum CommandOutcome: Equatable {
    case success(String?)
    case failure(String?)
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
    /// `source.kind == "user"` —— 插件注入的运行时上下文也走这个事件类型
    /// （`kind == "plugin"`，整段
    /// 沙箱与审批策略），不是人打的字，不该进对话流。
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
