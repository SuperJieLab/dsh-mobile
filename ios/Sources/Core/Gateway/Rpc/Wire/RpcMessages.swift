/**
 * 一元调用的信封：带 `v` / `ok` / `err` 的那种。
 *
 * 只有 HTTP 出现 —— 流帧没有这层壳。载荷本身不在这里，它们与链路无关，住根 `Wire/`。
 */
import Foundation

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

/// `session-create` 请求：**无载荷**。
///
/// 目录不由客户端指定 —— 宿主用它自己进程的当前目录。这不是遗漏：手机上不选目录是
/// 契约的一部分：目录由宿主决定，客户端不指定。
struct SessionCreateRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "session-create"
}

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

/// 响应信封的公共部分。载荷字段一律声明成可选：服务端拒绝时（`ok: false`）根本
/// 不会带载荷，声明成必选会让解码先一步失败，我们就拿不到那条有用的 `error` 了。
protocol GatewayResponse: Decodable {
    var v: Int { get }
    var ok: Bool { get }
    var error: GatewayFailure? { get }
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

/// `session-create` 回包。`sessionId` 是宿主建出来或复用的那个会话 —— 客户端不许自己造。
struct SessionCreateResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    var sessionId: String? = nil
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
