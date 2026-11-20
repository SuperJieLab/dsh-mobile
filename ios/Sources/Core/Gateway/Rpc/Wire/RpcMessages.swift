/**
 * 一元调用的两半：请求的端点名与参数、应答的业务字段。
 *
 * **信封不在这里**：`{type, rpcId, method, payload:{args}}` 与
 * `{type, rpcId, result:{ok, value|error}}` 由 `HttpTransport` 拼与拆 —— 那一层是唯一
 * 知道「这次调用怎么出门」的地方。这里只声明两端的**内容**：这次调的是哪个端点、
 * 参数长什么样、回来的业务字段有哪些。
 *
 * 形状与上游 Web UI 的 Connection RPC 逐字同形。没有版本字段：上游没有。
 */
import Foundation

/// 一条一元请求。
///
/// 端点名是**静态的**：它是这条请求的身份，不是一次调用的数据 —— 所以不进实例的编码，
/// 由传输层当路径与 `method` 用。字段（`sessionId` 之类）就是 `payload.args` 的内容。
///
/// 这一格也不是为了线上形状才有的：传输层记失败日志时要说清是哪一条（「endpoint refused」
/// 说不出是删工作空间还是拉列表），它同时是那个标识。
protocol GatewayRequest: Encodable {
    static var endpoint: String { get }
}

struct ModelCatalogRequest: GatewayRequest {
    static let endpoint = "session/modelCatalog"
}

/// `session/selectModel` 请求：`reasoningEffort` 为 `nil` 时整个字段不出现在 JSON 里
/// （合成编码用 `encodeIfPresent`）—— 「没指定」与「空串」是两回事（严格校验）。
struct ModelSelectRequest: GatewayRequest {
    static let endpoint = "session/selectModel"
    let sessionId: String
    let provider: String
    let model: String
    var reasoningEffort: String? = nil
}

/// `session/create` 请求：**至多一个工作空间**。
///
/// 不带 `workspaceId` 时目录由宿主进程的当前目录决定；带的时候落在那个工作空间的目录里，
/// 归属由宿主自己挂进成员表。
///
/// ⚠️ `nil` 必须**整个字段不出现**，不能编码成 `null`：网关按「有没有这个键」区分
/// 「不指定」与「指定了一个空值」，后者是畸形载荷、会被拒。所以这里的编码是手写的。
struct SessionCreateRequest: GatewayRequest {
    static let endpoint = "session/create"
    var workspaceId: String? = nil

    private enum CodingKeys: String, CodingKey { case workspaceId }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
    }
}

/// `mobile/workspaceCreate` 请求：只发一个名字 —— 目录落在哪由网关决定，客户端不指定路径。
struct WorkspaceCreateRequest: GatewayRequest {
    static let endpoint = "mobile/workspaceCreate"
    let name: String
}

struct CommandCatalogRequest: GatewayRequest {
    static let endpoint = "commands/list"
    let sessionId: String
}

/// `commands/execute` 请求。
///
/// **只发一整行文本**，不拆名字与参数：语法（含分隔符）由宿主定义，客户端拆一次就成了
/// 第二份实现 —— 上游改规则时这里不会编译失败，只会在某个参数上静默错位。
struct CommandExecuteRequest: GatewayRequest {
    static let endpoint = "commands/execute"
    let sessionId: String
    let line: String
}

/// 权限预设的读：这个会话此刻能选什么、现在是什么。
///
/// 带 `sessionId` 是因为**当前值是会话级的**（选项是进程级的）—— 两样一次拿齐，
/// 客户端就不必自己从沙箱模式与审批策略折叠出预设。
struct PermissionCatalogRequest: GatewayRequest {
    static let endpoint = "mobile/permissionCatalog"
    let sessionId: String
}

/// 权限预设的写：**只发预设名**。
///
/// 不发沙箱模式与审批策略：那两格是宿主折叠出预设的输入，发出去等于邀请客户端自己算一遍。
/// 预设名合不合法由宿主的目录说了算，客户端不维护第二份名单。
struct PermissionSelectRequest: GatewayRequest {
    static let endpoint = "mobile/permissionSelect"
    let sessionId: String
    let preset: String
}

/// 协议里的时刻是 **epoch 毫秒**（`1758000000000`），不是秒。
func epochMilliseconds(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value / 1000)
}

// MARK: - 请求（协议形状的唯一出处）

struct ListSessionsRequest: GatewayRequest {
    static let endpoint = "mobile/listSessions"
}

/// 配对：一次性配对码换设备凭证。**免票** —— 它的作用就是拿票。
struct PairRequest: GatewayRequest {
    static let endpoint = "mobile/pair"
    let code: String
}

/// 续期：设备凭证换访问凭证。**免票**，同上。
struct RefreshRequest: GatewayRequest {
    static let endpoint = "mobile/refresh"
    let deviceToken: String
}

struct SnapshotRequest: GatewayRequest {
    static let endpoint = "mobile/snapshot"
    let sessionId: String
    let since: Int
}

/// 可选字段为 `nil` 时不会出现在 JSON 里（合成实现用的是 `encodeIfPresent`），
/// 这正是协议要的形状：不传 `beforeSeq` 的意思是「从最新往回」，而不是「空值」。
struct PageRequest: GatewayRequest {
    static let endpoint = "mobile/page"
    let sessionId: String
    let beforeSeq: Int?
}

/// 审批应答：应答词汇表只有两键，映射在服务端完成 ——
/// `allow` → `allowed-once`（一次性，绝不推断持久授权）。
struct ApprovalAnswerRequest: GatewayRequest {
    static let endpoint = "mobile/approvalAnswer"
    let eventId: String
    let decision: String
    let answerId: String
}

/// 下发指令：`promptId` 是幂等键，服务端按它去重重复投递。
///
/// ⚠️ 上游把这一格叫 `requestId`，我们仍叫 `promptId` —— 改 wire 名是行为变更，
/// 不在「换信封」的范围里。
struct SessionPromptRequest: GatewayRequest {
    static let endpoint = "session/prompt"
    let sessionId: String
    let text: String
    let promptId: String
}

/// `workspace/delete` 请求：只带一个工作空间 id。
struct WorkspaceDeleteRequest: GatewayRequest {
    static let endpoint = "workspace/delete"
    let workspaceId: String
}

// MARK: - 应答（`result.value` 那一格）

/// 一次调用的业务字段。
///
/// **这里没有任何「成功与否」的知识** —— `ok` / `error` 在信封的 `result` 上，
/// 由传输层判一次（`RpcClient.perform` 的 `validate()`）。载荷字段一律声明成可选：
/// 服务端拒绝时 `value` 整个缺席，声明成必选会让解码先一步失败。
///
/// 这个协议现在只剩「约束泛型」一个用途；留着它是因为传输层的签名读起来比 `Decodable` 明确。
protocol GatewayResponse: Decodable {}

struct ListSessionsResponse: GatewayResponse {
    let sessions: [SessionSummary]?
    /// 工作空间清单，顺序即显示顺序。**缺席**表示这次应答没有分组能力（只读装配），
    /// 空数组表示宿主里一个工作空间也没有 —— 两者在界面上都表现为「全在未分组」，
    /// 但线上不能混成一种。
    let workspaces: [WorkspaceSummary]?
    /// 服务端时钟（epoch ms）—— 协议承诺在；clock 采样读它估两端 offset。
    /// 缺席按「服务端没给」处理，不猜。
    let serverTime: Double?
}

/// 配对回包：设备凭证只在这里出现一次。
struct PairResponse: GatewayResponse {
    let deviceToken: String?
}

/// 续期回包：访问凭证与过期时刻（epoch 毫秒）。
///
/// **`deviceToken` 是轮换后的设备凭证** —— 服务端每次续期都换一枚，旧的在宽限期内
/// 还能用一次。丢掉这个字段不会立刻坏，但会掉进宽限那条回头路，而下一次轮换之后就
/// 再也回不来了（那时只能重新配对）。
struct RefreshResponse: GatewayResponse {
    let accessToken: String?
    let expiresAt: Double?
    let deviceToken: String?
}

/// 快照回包：opening 的 `model` 字段是协议面，解码行为要能被
/// `tests/ModelProtocolTests.swift` 直接断言 —— `@testable import` 下 internal 即可测。
struct SnapshotResponse: GatewayResponse {
    let asOfSeq: Int?
    let hasMore: Bool?
    let events: [SessionEvent]?
    /// 下一轮将使用的模型；整个缺省 = 服务端不知道。
    var model: ModelSelection? = nil
}

struct PageResponse: GatewayResponse {
    let pageStart: Int?
    let asOfSeq: Int?
    let hasOlder: Bool?
    let events: [SessionEvent]?
}

/// 审批应答回包：成功不带业务字段。
struct ApprovalAnswerResponse: GatewayResponse {}

/// 下发指令回包：成功即已受理。
struct SessionPromptResponse: GatewayResponse {}

/// 目录回包：转发原样，只剥了宿主私有字段。
struct ModelCatalogResponse: GatewayResponse {
    var `default`: ModelSelection? = nil
    var groups: [ModelCatalogGroup]? = nil
    var failures: [ModelCatalogFailure]? = nil
}

/// 选择回包：`selected` 是上游归一化后的选择（不含 sessionId），透传不重推。
struct ModelSelectResponse: GatewayResponse {
    var selected: ModelSelection? = nil
}

/// `session/create` 回包。`sessionId` 是宿主建出来或复用的那个会话 —— 客户端不许自己造。
struct SessionCreateResponse: GatewayResponse {
    var sessionId: String? = nil
}

/// `mobile/workspaceCreate` 回包。
///
/// `created` 为假**不是失败**：这个名字已经在用，返回的是既有的那个。界面据它说不同的话。
struct WorkspaceCreateResponse: GatewayResponse {
    var workspaceId: String? = nil
    var title: String? = nil
    var created: Bool? = nil
}

/// `workspace/delete` 回包。
///
/// **没有业务字段** —— `ok` 就是结论：它已经不在列表里了。是真删掉的、还是另一端早就删了，
/// 客户端要做的事完全一样（关掉确认框、重拉一次），所以没有一格要读。
struct WorkspaceDeleteResponse: GatewayResponse {}

/// 命令列表回包。
struct CommandCatalogResponse: GatewayResponse {
    var commands: [CommandInfo]? = nil
}

/// 执行回包。**只有受理 id，没有执行结果** —— 结果从订阅流里的
/// `command/run` / `command/done` 来；两处都带就会出现「流里说失败、回包说成功」。
struct CommandExecuteResponse: GatewayResponse {
    var commandId: String? = nil
}

/// 权限预设的读回包。
///
/// **`options` 缺席与空数组是两件事**：缺席 = 这个装配没有权限服务（界面不画那一格）；
/// 空数组 = 服务在但一项都没配。合成一种，界面就会画一个点不开的格子。
struct PermissionCatalogResponse: GatewayResponse {
    var current: String? = nil
    var options: [PermissionOption]? = nil
}

/// 权限预设的写回包。`current` 是受理后**宿主重读投影**给的值，不是把发出去的那份当答案。
struct PermissionSelectResponse: GatewayResponse {
    var current: String? = nil
}
