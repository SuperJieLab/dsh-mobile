import Foundation

/// 协议版本，请求与响应都必须带它 —— 版本协商的位置。
let gatewayProtocolVersion = 2

/// 失败信封里的错误码（协议 v2 六个 + `unauthenticated` + `unknown-approval` /
/// `invalid-request` + `session/model-unavailable` + `window-too-large` + `unknown-command`）。
/// 收的时候刻意用 `String` 而非本枚举：上游加码时照原样显示，不能解不出来就崩。
/// `CaseIterable` 只为那一条「取值只写一处」的检查（`tests/ErrorCodeLiteralTests.swift`）：
/// 判据遍历 `allCases`，不必去解析源码猜协议里有哪些码。生产代码不遍历它。
enum GatewayErrorCode: String, CaseIterable {
    case unsupportedVersion = "unsupported-version"
    case unknownOp = "unknown-op"
    case unknownSession = "unknown-session"
    case unreadableSession = "unreadable-session"
    case internalError = "internal-error"
    case resyncRequired = "resync-required"
    case unauthenticated = "unauthenticated"
    case unknownApproval = "unknown-approval"
    case invalidRequest = "invalid-request"
    case sessionModelUnavailable = "session/model-unavailable"
    case windowTooLarge = "window-too-large"
    /// 那一行解析不出已注册的命令名，或语法不对 —— 用户改字就能修好，与「执行失败」不同。
    case unknownCommand = "unknown-command"
}

/// 失败信封里的 `error` 对象。
struct GatewayFailure: Decodable, Equatable {
    let code: String
    let message: String
}

// MARK: - 会话

/// 列表里的一行（协议 v2）。字段全来自会话 header 或 host 已维护的投影，没有一个读日志算出来
/// —— 列表因而零 I/O。
struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    /// **可选**：该会话没有标题、或那一行没有投影可用时，字段**整个缺失** ——
    /// 既不是 `null` 也不是空串。这是契约的一部分，不是故障。
    let title: String?
    /// 会话创建时间。**客户端当前不读它** —— 留作协议行的完整镜像。
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

/// 一条会话事件。协议承诺**事件体原样透传**（不裁剪、不翻译、不改名，且日后会带我们不认识的
/// 字段），所以只声明用到的四个，其余靠 `JSONValue` 原样收下不解析。
struct SessionEvent: Decodable, Equatable {
    let type: String
    let seq: Int
    let time: Double
    let data: JSONValue
}

/// 任意 JSON。存在的理由只有一条：**容忍不认识的字段** —— 声明成固定结构体的话，上游每加一个
/// 字段我们就得跟着改，那正是「桥接而非翻译」要避免的。
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
                debugDescription: "not null, number, bool, string, array or object"
            )
        }
    }

    /// 对称的编码：跟解码一样按实际类型走 —— `JSONValue` 要能在两个方向上
    /// 原样表示任意 JSON（订阅流要往回发帧）。
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

    /// 拿一个整数字段；拿不到就是 `nil`。凡要读协议对象的地方都用它（`TransientChannel`
    /// 不用它，只编协议层的测试脚本就不必连带编译一个用不到的状态机）。
    var int: Int? {
        if case .number(let value) = self, value == value.rounded(), value >= 0 { return Int(value) }
        return nil
    }
}

// MARK: - 上下文占用

/// 占用组成的三项。**不是** `usedTokens` 的分解 —— 估算器对中文与 JSON schema
/// 定价偏低，三项加起来不等于那个数。
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
    /// 组成三项。服务端「不知道」时整个缺失 —— 缺它**不减损**上面那个比例。
    ///
    /// ⚠️ 写成带默认值的 `var` 只为构造时能省略：memberwise init 不给 `let` + Optional 隐含缺省。
    var breakdown: UsageBreakdown? = nil
}

/// 一个水位上的一份占用读数。`usage` 缺失是一个**陈述**而不是故障：这个 cut 上没有可显示的
/// 东西，正在显示的旧值应当被清掉。
struct UsageSnapshot: Decodable, Equatable {
    /// 这份读数取自日志的哪个水位。⚠️ 与窗口的 `cursor` 是两条轴，**不要相减** —— 窗口按消息数切，
    /// 可能落后或领先投影折叠到的位置。
    let asOfSeq: Int
    /// 缺省 = 这个水位上没有可显示的东西（构造时可省略，理由同 `UsagePayload.breakdown`）。
    var usage: UsagePayload? = nil
}

// MARK: - 模型选择

/// 一次模型选择。`reasoningEffort` 缺省 = 不指定推理力度 ——
/// 字段缺省是协议的一部分（`encodeIfPresent`），不是故障。
struct ModelSelection: Codable, Equatable {
    let provider: String
    let model: String
    var reasoningEffort: String? = nil
}

/// 打开选择器时现拉一次的目录。服务端只转发与剥除宿主私有字段，
/// 不重排不补齐；`default` 整个缺省 = 无部署默认，客户端显示时不猜。
struct ModelCatalog: Decodable, Equatable {
    var `default`: ModelSelection? = nil
    var groups: [ModelCatalogGroup]? = nil
    var failures: [ModelCatalogFailure]? = nil
}

/// 目录里的一个 provider 分组。
struct ModelCatalogGroup: Decodable, Equatable {
    let id: String
    let name: String
    let models: [ModelCatalogEntry]
}

/// 分组里的一个可选项。`reasoning` 缺省 = 该模型不暴露推理力度选择。
struct ModelCatalogEntry: Decodable, Equatable {
    let id: String
    let name: String
    var reasoning: Reasoning? = nil

    /// 上游形状：`efforts` 是**对象数组**（每项有 `id` 与 `name`），不是 id 串 ——
    /// 按 `[String]` 解会让整份目录解码失败、菜单全空。
    struct Reasoning: Decodable, Equatable {
        let efforts: [Effort]
        var defaultEffort: String? = nil

        struct Effort: Decodable, Equatable {
            let id: String
            let name: String
            var description: String? = nil
        }
    }
}

/// 目录里的一个拉取失败的 provider —— 失败隔离，不炸整体（上游同语义）。
struct ModelCatalogFailure: Decodable, Equatable {
    let id: String
    let name: String
    let message: String
}

/// `model-catalog` 请求：只带信封。
struct ModelCatalogRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "model-catalog"
}

/// `model-select` 请求：`reasoningEffort` 为 `nil` 时整个字段不出现在 JSON 里
/// （合成编码用 `encodeIfPresent`）—— 「没指定」与「空串」是两回事（严格校验）。
struct ModelSelectRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "model-select"
    let sessionId: String
    let provider: String
    let model: String
    var reasoningEffort: String? = nil
}

// MARK: - 命令

/// 宿主的一条命令。名字与说明按宿主原样显示；`inputHint` 有值时当参数占位提示。
struct CommandInfo: Decodable, Equatable {
    let name: String
    let description: String
    var inputHint: String? = nil
}

/// `command-catalog` 请求：列某个会话此刻能用的命令。
struct CommandCatalogRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "command-catalog"
    let sessionId: String
}

/// `command-execute` 请求。
///
/// **只发一整行文本**，不拆名字与参数：语法（含分隔符）由宿主定义，客户端拆一次就成了
/// 第二份实现 —— 上游改规则时这里不会编译失败，只会在某个参数上静默错位。
struct CommandExecuteRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "command-execute"
    let sessionId: String
    let line: String
}

// MARK: - 时刻

/// 协议里的时刻是 **epoch 毫秒**（`1758000000000`），不是秒。
func epochMilliseconds(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value / 1000)
}

// MARK: - 请求（协议形状的唯一出处）

struct ListSessionsRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "list-sessions"
}

/// 配对：一次性配对码换设备凭证。身份不进消息体之外的位置 ——
/// 配对码就是这条消息的载荷，走与业务同一端点。
struct PairRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "pair"
    let code: String
}

/// 续期：设备凭证换访问凭证。
struct RefreshRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "refresh"
    let deviceToken: String
}

struct SnapshotRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "snapshot"
    let sessionId: String
    let since: Int
}

/// 可选字段为 `nil` 时不会出现在 JSON 里（合成实现用的是 `encodeIfPresent`），
/// 这正是协议要的形状：不传 `beforeSeq` 的意思是「从最新往回」，而不是「空值」。
struct PageRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "page"
    let sessionId: String
    let beforeSeq: Int?
    let maxMessages: Int?
}

/// 审批应答：应答词汇表只有两键，映射在服务端完成 ——
/// `allow` → `allowed-once`（一次性，绝不推断持久授权）。
struct ApprovalAnswerRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "approval-answer"
    let eventId: String
    let decision: String
    let answerId: String
}

/// 下发指令：`promptId` 是幂等键，服务端按它去重重复投递。
struct SessionPromptRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "session-prompt"
    let sessionId: String
    let text: String
    let promptId: String
}

// MARK: - 响应信封

/// 响应信封的公共部分。载荷字段一律声明成可选：服务端拒绝时（`ok: false`）根本
/// 不会带载荷，声明成必选会让解码先一步失败，我们就拿不到那条有用的 `error` 了。
protocol GatewayResponse: Decodable {
    var v: Int { get }
    var ok: Bool { get }
    var error: GatewayFailure? { get }
}

extension GatewayResponse {
    func validate() throws {
        guard v == gatewayProtocolVersion else {
            throw GatewayClientError.versionMismatch(v)
        }
        guard ok else {
            throw GatewayClientError.refused(
                error ?? GatewayFailure(code: GatewayErrorCode.internalError.rawValue,
                                        message: "")
            )
        }
    }
}

struct ListSessionsResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let sessions: [SessionSummary]?
    /// 服务端时钟（epoch ms）—— 协议承诺在；clock 采样读它估两端 offset。
    /// 缺席按「服务端没给」处理，不猜。
    let serverTime: Double?
}

/// 配对回包：设备凭证只在这里出现一次。
struct PairResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let deviceToken: String?
}

/// 续期回包：访问凭证与过期时刻（epoch 毫秒）。
struct RefreshResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let accessToken: String?
    let expiresAt: Double?
}

/// 快照回包：opening 的 `model` 字段是协议面，
/// 解码行为要能被 `tests/ModelProtocolTests.swift` 直接断言 ——
/// `@testable import` 下 internal 即可测。
struct SnapshotResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let asOfSeq: Int?
    let hasMore: Bool?
    let events: [SessionEvent]?
    /// 下一轮将使用的模型；整个缺省 = 服务端不知道。
    var model: ModelSelection? = nil
}

struct PageResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let pageStart: Int?
    let asOfSeq: Int?
    let hasOlder: Bool?
    let events: [SessionEvent]?
}

/// 审批应答回包：成功不带载荷。
struct ApprovalAnswerResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
}

/// 下发指令回包：成功即已受理。
struct SessionPromptResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
}

/// 目录回包：转发原样，只剥了宿主私有字段。
struct ModelCatalogResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    var `default`: ModelSelection? = nil
    var groups: [ModelCatalogGroup]? = nil
    var failures: [ModelCatalogFailure]? = nil
}

/// 选择回包：`selected` 是上游归一化后的选择（不含 sessionId），透传不重推。
struct ModelSelectResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    var selected: ModelSelection? = nil
}

/// 命令列表回包。
struct CommandCatalogResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    var commands: [CommandInfo]? = nil
}

/// 执行回包。**只有受理 id，没有执行结果** —— 结果从订阅流里的
/// `command/run` / `command/done` 来；两处都带就会出现「流里说失败、回包说成功」。
struct CommandExecuteResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    var commandId: String? = nil
}

// MARK: - 快照结果

/// 一次快照的结果。`Equatable` 是状态机的需要：`Outcome` 要能比较，
/// 而它装着这个类型。
struct SessionSnapshot: Equatable {
    /// 本次覆盖到的位置（不含）—— 回传它就能拿到「空增量」，是水位不变式的用法。
    let asOfSeq: Int
    /// 服务端是否还有没给完的事件。为真就接着要 —— 单次响应有上限。
    let hasMore: Bool
    let events: [SessionEvent]
    /// 会话的模型基线：**下一轮**将使用的模型。缺省 = 服务端不知道，
    /// 客户端退到目录默认；进会话后的增量走订阅流。
    var model: ModelSelection? = nil
}

// MARK: - 回溯窗口结果

/// 一段往回读的窗口。与 `SessionSnapshot` 是两个方向：快照从 `since` 往后走，窗口
/// 从某个位置往回走。打开会话用后者取最近一段，之后用前者追新增 —— 客户端**不需要跨会话记住
/// 任何位置**，冷启动永远从「现在的最新一段」开始。
struct SessionPage: Equatable {
    /// 窗口首个事件的 `seq` —— 即下一次往回翻时的 `beforeSeq`。
    let pageStart: Int
    /// 窗口末尾（不含）。与 `SessionSnapshot.asOfSeq` 同义。
    let asOfSeq: Int
    /// 窗口之前还有事件吗。`false` 表示已经到日志开头。
    let hasOlder: Bool
    let events: [SessionEvent]
}
