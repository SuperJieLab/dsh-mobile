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

/// 宿主的 `request` 容器 —— 三条写 op（`session/selectModel`、`session/create`、
/// `workspace/delete`）的宿主形参都叫 `request`，线上因此多一层。
///
/// 少一层是旧客户端的形状，网关按畸形拒（`invalid-request`）；所以这里必须写出来，
/// 不能指望「平铺也能收」。
private enum RequestContainerKeys: String, CodingKey { case request }

/// `session/selectModel` 请求：`reasoningEffort` 为 `nil` 时整个字段不出现在 JSON 里
/// （`encodeIfPresent`）—— 「没指定」与「空串」是两回事（严格校验）。
struct ModelSelectRequest: GatewayRequest {
    static let endpoint = "session/selectModel"
    let sessionId: String
    let provider: String
    let model: String
    var reasoningEffort: String? = nil

    private enum PayloadKeys: String, CodingKey { case sessionId, provider, model, reasoningEffort }

    func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: RequestContainerKeys.self)
        var payload = outer.nestedContainer(keyedBy: PayloadKeys.self, forKey: .request)
        try payload.encode(sessionId, forKey: .sessionId)
        try payload.encode(provider, forKey: .provider)
        try payload.encode(model, forKey: .model)
        try payload.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }
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

    private enum PayloadKeys: String, CodingKey { case workspaceId }

    func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: RequestContainerKeys.self)
        var payload = outer.nestedContainer(keyedBy: PayloadKeys.self, forKey: .request)
        try payload.encodeIfPresent(workspaceId, forKey: .workspaceId)
    }
}

/// `mobile/workspaceCreate` 请求：只发一个名字 —— 目录落在哪由网关决定，客户端不指定路径。
struct WorkspaceCreateRequest: GatewayRequest {
    static let endpoint = "mobile/workspaceCreate"
    let name: String
}

/// `commands/list` 请求：**宿主的参数名是 `agentId`**（`agentId` 与 `sessionId` 同值 ——
/// 宿主把 `Agent` 序列化成一个 id）。
struct CommandCatalogRequest: GatewayRequest {
    static let endpoint = "commands/list"
    let agentId: String
}

/// `commands/execute` 请求。
///
/// **只发一整行文本**，不拆名字与参数：语法（含分隔符）由宿主定义，客户端拆一次就成了
/// 第二份实现 —— 上游改规则时这里不会编译失败，只会在某个参数上静默错位。
struct CommandExecuteRequest: GatewayRequest {
    static let endpoint = "commands/execute"
    let agentId: String
    let line: String
    /// 附件本期不接：线上这个键必须出现（宿主的必填形参），值恒为空数组。
    let submittedAttachments: NoAttachments
}

extension CommandExecuteRequest {
    init(agentId: String, line: String) {
        self.init(agentId: agentId, line: line, submittedAttachments: NoAttachments())
    }
}

/// 「这次没有附件」—— 只编码成 `[]`。
///
/// 用 `[JSONValue]` 会诱使后来的人往里塞东西，而附件这条路（上传、引用、宿主侧落盘）
/// 一期都没接；拿一个不可构造的类型顶住，缺的那一半就是看得见的。
struct NoAttachments: Encodable {
    func encode(to encoder: any Encoder) throws {
        _ = encoder.unkeyedContainer()
    }
}

/// 权限目录：**无参**。目录是进程级的；「这个会话现在是哪一档」在 `permissions` 投影里。
struct PermissionCatalogRequest: GatewayRequest {
    static let endpoint = "permissionPresets/catalog"
}

/// 协议里的时刻是 **epoch 毫秒**（`1758000000000`），不是秒。
func epochMilliseconds(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value / 1000)
}

// MARK: - 请求（协议形状的唯一出处）

/// `session/list` 请求：参数在 `_request` 这一层容器里（宿主的参数名就是它）。
///
/// 客户端只做一次**全量**读，不带 `cursor`：上游的 `cursor` 是增量分页用的，手机的列表
/// 走「全量 + 事件增量」，不需要它。
struct ListSessionsRequest: GatewayRequest {
    static let endpoint = "session/list"

    private enum CodingKeys: String, CodingKey { case request = "_request" }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EmptyArgs(), forKey: .request)
    }
}

/// 编码成 `{}` 的参数容器 —— `EmptyArgs()` 不带任何键。
struct EmptyArgs: Encodable {}

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

/// `session/page` 请求：参数在 `request` 这一层容器里（宿主的形参名就是它）。
///
/// `throughSeq` 与 `beforeSeq` 各管一件事：前者钉「日志长到哪为止」—— 打开那一刻的
/// `cursor`，翻页时**原样带回**；后者钉「这一页往前到哪」—— 本地窗口起点，每次递减。
/// 两个都发，不矛盾。
struct PageRequest: GatewayRequest {
    static let endpoint = "session/page"

    let sessionId: String
    let throughSeq: Int
    let beforeSeq: Int

    private enum CodingKeys: String, CodingKey { case request }
    private enum RequestKeys: String, CodingKey {
        case address, throughSeq, beforeSeq, maxMessages, turnWindow
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var request = container.nestedContainer(keyedBy: RequestKeys.self, forKey: .request)
        try request.encode(SessionAddress(sessionId: sessionId), forKey: .address)
        try request.encode(throughSeq, forKey: .throughSeq)
        try request.encode(beforeSeq, forKey: .beforeSeq)
        try request.encode(HistoryWindow.standard.maxMessages, forKey: .maxMessages)
        try request.encode(HistoryWindow.standard.turnWindow, forKey: .turnWindow)
    }
}

/// 审批应答：应答词汇表只有两键，映射在服务端完成 ——
/// `allow` → `allowed-once`（一次性，绝不推断持久授权）。
struct ApprovalAnswerRequest: GatewayRequest {
    static let endpoint = "mobile/approvalAnswer"
    let eventId: String
    let decision: String
    /// 幂等键：同键重试，网关回放第一次的结论。
    let answerId: String
    /// 这条审批是在哪条流上看到的 —— 网关按它判「是不是你」。
    /// 取自最近一次 `ready` 的 `clientId`，由 `ApprovalStore` 从流上读出来。
    let clientId: String
}

/// 一个问题的一道答案 —— 字段与网关 `QuestionAnswerMessage` 的 `answers` 元素逐字相同。
///
/// `custom` 缺席时整个键不出现（合成的 `Encodable` 对 Optional 用 `encodeIfPresent`），
/// 与网关那侧「缺席 ≠ 空串」一致。
struct QuestionAnswerItem: Encodable {
    let id: String
    /// 选中的选项 label；只填自由文本时是空数组。
    let selected: [String]
    /// 「其它」的自由文本，可与选项并存。
    let custom: String?
}

/// 一张卡的整批答案。**`answerId` 的主键是卡**，不是单个问题 —— 一卡一次提交。
///
/// 答案必须覆盖卡上全部 `id`（一个不缺、一个不多），否则网关回 `invalid-request`
/// 且不投递。这条约束在这里表达不出来，客户端提交前自己保证。
struct QuestionAnswerRequest: GatewayRequest {
    static let endpoint = "mobile/questionAnswer"
    let eventId: String
    let answers: [QuestionAnswerItem]
    let answerId: String
    /// 这条提问是在哪条流上看到的 —— 与审批应答同一条归属判定。
    let clientId: String
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

    private enum PayloadKeys: String, CodingKey { case workspaceId }

    func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: RequestContainerKeys.self)
        var payload = outer.nestedContainer(keyedBy: PayloadKeys.self, forKey: .request)
        try payload.encode(workspaceId, forKey: .workspaceId)
    }
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
    /// 会话行。**分组不在这里**（组来自 `workspace/follow`），标题在每行的投影块里。
    let items: [SessionSummary]?
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

/// `session/page` 回包 —— 与打开帧的 `records` 同型（`{type:"event", event}`）。
///
/// 三个键缺一即为畸形应答（调用方抛 `malformedResponse`，不补默认值）：
/// `cursor` 是**含端**切点（不是这一页的起点），`hasMore` 说更早还有没有。
struct PageResponse: GatewayResponse {
    let records: [FailableDecodable<SessionRecord>]?
    let cursor: Int?
    let hasMore: Bool?
}

/// 审批应答回包：成功不带业务字段。
struct ApprovalAnswerResponse: GatewayResponse {}

/// 一张卡的答案回包：成功即已投递。结局由上游结算，客户端不推演。
struct QuestionAnswerResponse: GatewayResponse {}

/// 下发指令回包：成功即已受理。
struct SessionPromptResponse: GatewayResponse {}

/// 目录回包：**宿主目录的原样**（四个键，含 `routableProviders`）。
///
/// `routableProviders` 客户端目前不读，但它在线上形状里 —— 声明出来是为了让「目录被裁过」
/// 这件事看得见：少一个字段不会解码失败（JSONDecoder 容忍未知键），只会让下次要用的人
/// 以为它不存在。
struct ModelCatalogResponse: GatewayResponse {
    var `default`: ModelSelection? = nil
    var routableProviders: [String]? = nil
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

/// 命令列表回包 —— 线上是**裸数组**（上游这条回的就是一串描述符）。
///
/// 不声明成 `[CommandDescriptor]` 是因为协议要求 `Decodable` 的类型；这里手写
/// 一个从 unkeyed 容器读的壳，调用点因此仍读 `response.commands`。
struct CommandCatalogResponse: GatewayResponse {
    let commands: [CommandDescriptor]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var commands: [CommandDescriptor] = []
        while !container.isAtEnd {
            commands.append(try container.decode(CommandDescriptor.self))
        }
        self.commands = commands
    }
}

/// 执行回包。**只有受理 id，没有执行结果** —— 结果从订阅流里的
/// `command/run` / `command/done` 来；两处都带就会出现「流里说失败、回包说成功」。
struct CommandExecuteResponse: GatewayResponse {
    var commandId: String? = nil
}

/// 权限目录回包。
///
/// **三键一起缺席与空数组是两件事**：缺席 = 这个装配没有权限服务（界面不画那一格）；
/// 空数组 = 服务在但一项都没配。合成一种，界面就会画一个点不开的格子。
struct PermissionCatalogResponse: GatewayResponse {
    var options: [PermissionOption]? = nil
    var defaultOptions: [PermissionOption]? = nil
    var defaultPreset: String? = nil
}
