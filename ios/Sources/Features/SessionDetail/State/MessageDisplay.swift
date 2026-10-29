/**
 * 哪些事件能变成一条消息、取哪个文本块 —— 显示取舍，不是协议规则。
 *
 * `DisplayMessage` 与 `Role` 是它的输出形状，不是线上形状。消费者是 `TranscriptAssembler`
 * 与 `SessionDetailView`；消息条数由装配好的节点数出来，不遍历事件另算一份。
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

    /// 一次命令的生命周期。上游记成两条配对事件（`command/run` 与 `command/done`，由
    /// `commandId` 关联），都是 **log-only**：不进模型 transcript。
    /// 与 `displayMessage` 分开：命令不是对话消息，不套气泡、不算某人的发言。
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
    /// ⚠️ **两种事件的消息不在同一处**：`user/message` 在 `data` 上，`assistant/message` 在
    /// `data.message` 上。只取 `text` 块（`reasoning` 与工具块不上屏）。
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
