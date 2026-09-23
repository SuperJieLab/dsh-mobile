import Foundation

/// 协议版本。请求与响应都必须带它 —— 这是版本协商的位置，现在就留好。
///
/// 对应 `docs/dev/protocol.md` §三。
let gatewayProtocolVersion = 2

/// 失败信封里的错误码。协议 v2 有这六个，M4 起新增 `unauthenticated`（鉴权域），
/// M5 起新增 `unknown-approval` / `invalid-request`（写操作域）。
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
    case unauthenticated = "unauthenticated"
    case unknownApproval = "unknown-approval"
    case invalidRequest = "invalid-request"

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
        case .unauthenticated:
            return "没有可用的身份 —— 未配对或配对已被撤销。"
        case .unknownApproval:
            return "这条审批已经不在了 —— 可能已被取消或在 Mac 上处理过。"
        case .invalidRequest:
            return "网关拒绝了这条写请求的载荷 —— 两端版本可能不一致。"
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
/// 算出来的**，这正是列表能做到零 I/O 的原因（`docs/dev/protocol.md` §4.1）。
struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    /// **可选**：该会话没有标题、或那一行没有投影可用时，字段**整个缺失** ——
    /// 既不是 `null` 也不是空串。这是契约的一部分，不是故障。
    let title: String?
    /// 会话创建时间。**客户端当前不读它** —— 留作协议行的完整镜像（协议给了哪几个
    /// 时间，看这里就知道；删掉不会让解码更快，只会让口径少一处）。
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
struct SessionEvent: Decodable, Equatable {
    let type: String
    let seq: Int
    let time: Double
    let data: JSONValue
}

/// 任意 JSON。存在的理由只有一条：**容忍不认识的字段**。
///
/// 若把 `data` 声明成固定的结构体，上游每加一个字段我们就得跟着改 ——
/// 那正是协议里「桥接而非翻译」这条约束要避免的事。
enum JSONValue: Decodable, Encodable, Equatable {
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

    /// 对称的编码：跟解码一样按实际类型走 —— `JSONValue` 要能在两个方向上
    /// 原样表示任意 JSON（M2 的跟随流要往回发帧）。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
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

    /// 拿一个整数字段；拿不到就是 `nil`。
    ///
    /// 与 `JSONValue` 同层：它是这个类型自己的取值辅助，凡是要读协议对象的
    /// 地方都要用（原先寄居在 `TransientChannel` 里，会让只编协议层的测试脚本
    /// 连带编译一个用不到的状态机）。
    var int: Int? {
        if case .number(let value) = self, value == value.rounded(), value >= 0 { return Int(value) }
        return nil
    }
}

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

// MARK: - 上下文占用（M6）

/// 占用组成的三项。**不是** `usedTokens` 的分解 —— 估算器对中文与 JSON schema
/// 定价偏低，三项加起来不等于那个数（`docs/dev/plans/M6-presentation-layer.md` §3.1 决定 6）。
struct UsageBreakdown: Decodable, Equatable {
    let systemTokens: Int
    let toolsTokens: Int
    let messageTokens: Int
}

/// 手机上要画的那个比例。
struct UsagePayload: Decodable, Equatable {
    /// 分子。服务端已按「provider 报的数优先，启发式重定价次之」算好，客户端不再自己推。
    let usedTokens: Int
    /// 分母 —— 路由声明的上下文容量。
    let contextWindow: Int
    /// 组成三项。服务端认为「不知道」时整个缺失 —— 缺它**不减损**上面那个比例。
    ///
    /// ⚠️ 写成带默认值的 `var` 只为让构造时能省略它 —— Swift 的 memberwise init
    /// 不给 `let` + Optional 隐含缺省，而这两个类型构造出来就不再被改。
    var breakdown: UsageBreakdown? = nil
}

/// 一个水位上的一份占用读数。
///
/// `usage` 缺失是一个**陈述**而不是故障：这个 cut 上没有可显示的东西，
/// 正在显示的旧值应当被清掉（`docs/dev/plans/M6-presentation-layer.md` §3.1 决定 4）。
struct UsageSnapshot: Decodable, Equatable {
    /// 这份读数取自日志的哪个水位。⚠️ 与窗口的 `cursor` 是两条轴，**不要相减** ——
    /// 窗口按消息数切，可能落后或领先投影折叠到的位置。
    let asOfSeq: Int
    /// 缺省 = 这个水位上没有可显示的东西（构造时可省略，理由同 `UsagePayload.breakdown`）。
    var usage: UsagePayload? = nil
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
