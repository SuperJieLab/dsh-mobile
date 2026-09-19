import Foundation

/// 协议版本。请求与响应都必须带它 —— 这是版本协商的位置，现在就留好。
///
/// 对应 `docs/protocol.md` §三。
let gatewayProtocolVersion = 2

/// 失败信封里的错误码。协议 v2 有这六个。
///
/// 但收的时候刻意用 `String` 而不是这个枚举：上游日后加码时，
/// 客户端应当照原样显示，而不是因为解不出来就崩掉。
enum GatewayErrorCode: String {
    case unsupportedVersion = "unsupported-version"
    case unknownOp = "unknown-op"
    case unknownSession = "unknown-session"
    case unreadableSession = "unreadable-session"
    case internalError = "internal-error"
    case resyncRequired = "resync-required"

    /// 人话解释，用于把服务端的拒绝变成用户看得懂的一句话。未知码返回 nil。
    var explanation: String? {
        switch self {
        case .unsupportedVersion:
            return "网关不认识这次请求的协议版本 —— 两端版本不一致。"
        case .unknownOp:
            return "网关不认识这个操作名 —— 客户端用了一个服务端没有的 op。"
        case .unknownSession:
            return "这个会话在 Mac 上找不到了 —— 可能已被删除。"
        case .unreadableSession:
            return "会话存在，但这个版本的 DSH 读不懂它的日志。"
        case .internalError:
            return "网关自身出错 —— 进程还活着，只是这次请求失败了。"
        case .resyncRequired:
            return "本机记的位置在 Mac 上不存在了 —— 正在从头发起一次同步。"
        }
    }
}

/// 失败信封里的 `error` 对象。
struct GatewayFailure: Decodable {
    let code: String
    let message: String

    /// 优先给中文解释，否则回落显示服务端原文。
    var readableDescription: String {
        GatewayErrorCode(rawValue: code)?.explanation ?? message
    }
}

// MARK: - 会话

/// 列表里的一行（协议 v2）。
///
/// 这里每个字段都来自会话 header 或 host 已经维护的投影 —— **没有一个是读日志
/// 算出来的**，这正是列表能做到零 I/O 的原因（`docs/protocol.md` §4.1）。
struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    /// **可选**：该会话没有标题、或那一行没有投影可用时，字段**整个缺失** ——
    /// 既不是 `null` 也不是空串。这是契约的一部分，不是故障。
    let title: String?
    let createdAt: Double
    /// **最后一次用户发言的时间**，没有则等于 `createdAt`。
    /// ⚠️ 不是「最后一次事件的时间」—— 助手输出与工具调用不推进它。
    let updatedAt: Double
    /// 这个会话当前有 agent 在跑吗。
    let running: Bool
    /// 还没有任何 turn 的会话 —— 工作区里那行候补的「新会话」。
    let blank: Bool
    /// `"subagent"` 表示它是另一个会话的子会话；普通会话没有这个字段。
    let origin: String?
}

// MARK: - 事件

/// 一条会话事件。
///
/// 协议承诺**事件体原样透传**，服务端不裁剪、不翻译、不改名，
/// 且日后会带上客户端还不认识的字段。所以这里只声明我们确实用到的四个，
/// 其余的靠 `JSONValue` 原样收下文、不解析。
struct SessionEvent: Decodable, Equatable, Identifiable {
    let type: String
    let seq: Int
    let time: Double
    let data: JSONValue

    var id: Int { seq }
}

/// 任意 JSON。存在的理由只有一条：**容忍不认识的字段**。
///
/// 若把 `data` 声明成固定的结构体，上游每加一个字段我们就得跟着改 ——
/// 那正是协议里「桥接而非翻译」这条约束要避免的事。
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "既不是 null、数字、布尔、字符串，也不是数组或对象"
            )
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// 取对象里的一个键；拿不到就是 nil。
    subscript(key: String) -> JSONValue? { object?[key] }
}

// MARK: - 从事件里抽出可显示的消息

/// 屏幕上显示的一条消息气泡。
struct DisplayMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
    }

    /// 直接用事件 `seq` 当身份 —— 它在会话内唯一且稳定，不需要另造 id。
    var id: Int { seq }

    let seq: Int
    let role: Role
    let text: String
    let time: Double
}

extension SessionEvent {
    /// 把一条事件变成一条可显示的消息；变不出来就是 `nil`。
    ///
    /// ⚠️ **两种事件的消息不是一个形状**（实测得出，不是猜的）：
    /// - `user/message` —— 消息对象**直接在 `data` 上**：`data.content` / `data.role` / `data.source`
    /// - `assistant/message` —— 消息包在 **`data.message`** 里，与 `data.usage` / `data.stream` 并列
    ///
    /// 把这个不对称当成对称处理，症状是**用户消息被静默吞掉**（探针实测：6 条消息事件只认出 1 条）。
    ///
    /// 两条显示规则（都是**显示**决策，不是协议规则 —— 协议只管原样透传）：
    /// - 只取 `text` 块。助手的 `reasoning`（思考）与 `tool-call`（工具调用）属于过程，不属于对话内容。
    /// - `user/message` 只认 `source.kind == "user"` 的。**插件注入的运行时上下文也走这个事件类型**
    ///   （`source.kind == "plugin"`，内容是整段沙箱与审批策略），它不是人打的字，不该进对话流。
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

// MARK: - 时刻

/// 协议里的时刻是 **epoch 毫秒**（`1758000000000`），不是秒。
func epochMilliseconds(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value / 1000)
}

/// 列表与详情里统一用的相对时间显示。
func relativeTime(_ value: Double) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: epochMilliseconds(value), relativeTo: Date())
}
