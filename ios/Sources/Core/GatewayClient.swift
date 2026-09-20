import Foundation

/// 与 Mac 侧网关切口的**唯一**接触点。
///
/// 它做四件事：拼请求信封、发一次 `POST /rpc`、按信封判成败、以及 M4 的
/// **身份**——每个请求带 `Authorization`，401 时用设备凭证静默续期一次再重试。
///
/// 协议的类型与语义都在 `GatewayProtocol.swift` 里，SwiftUI 在这里没有位置 ——
/// 这与 Mac 侧把协议写成纯函数 `handle(msg)` 是同一个手法：
/// 协议处理不该和它的使用者缠在一起。
///
/// `struct` 改 `class`（M4）：续期单飞与已配对状态是**可变共享状态**，值语义
/// 会在视图间复制出各自为政的凭证。仍是 `@MainActor` —— 所有调用方本就在主线程。
@MainActor
final class GatewayClient: ObservableObject {
    let baseURL: URL

    /// 协议里的唯一端点。多端点会把资源语义烧进 URL（见 `docs/protocol.md` §二）。
    nonisolated static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

    /// 三张票在手机侧的家（M4）。默认共享单例：全 App 一个身份。
    private let credentials: CredentialStore

    /// 续期单飞：同一时刻只允许一个 `refresh` 在途（Plan §3.6 的 401 竞态）。
    /// 并发撞上 401 的请求都等这一张新票，然后各自重试一次。
    private var refreshTask: Task<Bool, Never>?

    /// 关系是否存在（设备凭证在 Keychain 里）。配对成功置真，被撤销置假。
    @Published private(set) var isPaired: Bool

    init(baseURL: URL, credentials: CredentialStore? = nil) {
        self.baseURL = baseURL
        // 默认共享单例：全 App 一个身份（nil 默认值避开跨 actor 的默认表达式求值）。
        self.credentials = credentials ?? .shared
        self.isPaired = self.credentials.hasDeviceToken
    }

    /// 配对：用 Mac 屏幕上的一次性配对码换设备凭证（M4 §3.2）。
    /// 成功即建立关系；失败的文案来自服务端（配对码不对 / 过期 / 作废）。
    func pair(code: String) async throws {
        let response: PairResponse = try await send(PairRequest(code: code), authenticated: false)
        try response.validate()
        guard let deviceToken = response.deviceToken else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里没有 deviceToken")
        }
        credentials.saveDeviceToken(deviceToken)
        isPaired = true
    }

    /// 用设备凭证换一张新 access（M4 §3.3）。返回 false 表示关系已被服务端
    /// 掐断（401）——此时清掉本机凭证，App 回到未配对状态。
    ///
    /// 单飞：撞车的调用共享同一个在途任务的结果，不叠加请求。
    private func refreshAccess() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self, let deviceToken = self.credentials.deviceToken else { return false }
            do {
                let response: RefreshResponse = try await self.send(
                    RefreshRequest(deviceToken: deviceToken), authenticated: false
                )
                try response.validate()
                guard let token = response.accessToken, let expiresAt = response.expiresAt else { return false }
                self.credentials.storeAccess(token, expiresAt: Date(timeIntervalSince1970: expiresAt / 1000))
                return true
            } catch GatewayClientError.unauthenticated {
                // 服务端不认这段关系了：撤销或凭证被替换。掐断本机状态。
                self.credentials.deleteDeviceToken()
                self.isPaired = false
                return false
            } catch {
                // 传输失败不是关系终结：票换不到只是暂时，下次再试。
                return false
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return await task.value
    }

    // MARK: - 三个读 op

    /// 拉会话列表。服务端已按 `updatedAt` 降序排好 —— 协议规定客户端**不必自己排**。
    func listSessions() async throws -> [SessionSummary] {
        let response: ListSessionsResponse = try await send(ListSessionsRequest())
        try response.validate()
        return response.sessions ?? []
    }

    /// 拉某会话的快照。
    /// - Parameter since: 客户端**下一个期望的 seq** —— 由本地镜像记着，不是每次传 0。
    func snapshot(sessionId: String, since: Int = 0) async throws -> SessionSnapshot {
        let response: SnapshotResponse = try await send(
            SnapshotRequest(sessionId: sessionId, since: since)
        )
        try response.validate()
        // `ok: true` 却没有载荷是服务端的错，不该被默认值悄悄盖过去。
        guard let asOfSeq = response.asOfSeq, let events = response.events else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里没有 asOfSeq / events")
        }
        return SessionSnapshot(
            sessionId: response.sessionId ?? sessionId,
            asOfSeq: asOfSeq,
            // 缺省 `false`：不带这个字段的是旧服务端，它只会一次给完（协议 §五）。
            hasMore: response.hasMore ?? false,
            events: events
        )
    }

    /// 拉一段回溯窗口 —— 打开会话与往回翻都用它。
    /// - Parameters:
    ///   - beforeSeq: 窗口上界（不含）。不传表示「从最新往回」，即打开会话；
    ///     往回翻时传上一次的 `pageStart`。
    ///   - maxMessages: 最多取多少条消息。不传就用服务端的默认值。
    func page(sessionId: String, beforeSeq: Int? = nil, maxMessages: Int? = nil) async throws -> SessionPage {
        let response: PageResponse = try await send(
            PageRequest(sessionId: sessionId, beforeSeq: beforeSeq, maxMessages: maxMessages)
        )
        try response.validate()
        // `ok: true` 却没有载荷是服务端的错，不该被默认值悄悄盖过去。
        guard let pageStart = response.pageStart,
              let asOfSeq = response.asOfSeq,
              let hasOlder = response.hasOlder,
              let events = response.events else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里缺少 pageStart / asOfSeq / hasOlder / events")
        }
        return SessionPage(
            sessionId: response.sessionId ?? sessionId,
            pageStart: pageStart,
            asOfSeq: asOfSeq,
            hasOlder: hasOlder,
            events: events
        )
    }

    // MARK: - 两个写 op（M5）

    /// 应答一条审批。`ok` 只意味着**已投递**——权威结果以流里的
    /// `approval/decided` 为准（Plan §3.3 决定 3）。失败时如实上抛：
    /// `unknown-approval` 表示这条审批已经不在了。
    func answerApproval(eventId: String, allow: Bool, answerId: String) async throws {
        let response: ApprovalAnswerResponse = try await send(
            ApprovalAnswerRequest(eventId: eventId, decision: allow ? "allow" : "deny", answerId: answerId)
        )
        try response.validate()
    }

    /// 下发一条指令（发消息进会话）。`ok` 意味着**已受理**——回答本身从流里来。
    func sendPrompt(sessionId: String, text: String, promptId: String) async throws {
        let response: SessionPromptResponse = try await send(
            SessionPromptRequest(sessionId: sessionId, text: text, promptId: promptId)
        )
        try response.validate()
    }

    // MARK: - 发一次请求（带身份）

    private func send<Request: Encodable, Response: Decodable>(
        _ request: Request,
        authenticated: Bool = true,
        as: Response.Type = Response.self
    ) async throws -> Response {
        if let answer = try await sendOnce(request, authenticated: authenticated, type: Response.self) {
            return answer
        }
        // 走到这里 = 业务请求被 401 拒了（pair / refresh 的 401 在 sendOnce 里
        // 自带语义上抛，不会返回 nil）。换一张票（单飞），恰好重试一次。
        guard authenticated, await refreshAccess() else {
            throw GatewayClientError.unauthenticated
        }
        if let answer = try await sendOnce(request, authenticated: authenticated, type: Response.self) {
            return answer
        }
        throw GatewayClientError.unauthenticated
    }

    /// 发一次。返回 `nil` 表示被 401 拒了 —— 由 `send` 决定续期重试还是如实上抛。
    private func sendOnce<Request: Encodable, Response: Decodable>(
        _ request: Request,
        authenticated: Bool,
        type: Response.Type
    ) async throws -> Response? {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(Self.rpcPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 身份只走传输头，不进消息体（docs/protocol.md §「身份」）。
        if authenticated, let access = credentials.validAccessToken() {
            urlRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let payload: Data
        let urlResponse: URLResponse
        do {
            (payload, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw GatewayClientError.transport(url: urlRequest.url ?? baseURL, underlying: error)
        }

        if let http = urlResponse as? HTTPURLResponse {
            guard http.statusCode != 401 else {
                // 业务请求的 401 是「换个票再来」的信号，返回 nil 交外层续期重试；
                // 鉴权请求（pair / refresh）的 401 自带语义，必须读出信封上抛：
                // 配对码不对要说「配对码不对」，不是笼统的未认证。
                guard authenticated else {
                    if let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: payload),
                       let failure = envelope.error {
                        if failure.code == GatewayErrorCode.unauthenticated.rawValue {
                            throw GatewayClientError.unauthenticated
                        }
                        throw GatewayClientError.refused(failure)
                    }
                    throw GatewayClientError.unauthenticated
                }
                return nil
            }
            if http.statusCode != 200 {
                throw GatewayClientError.badStatus(http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            // 解不出来时先看看能不能读出信封里的 error —— 服务端的拒绝
            // 比解码器的报错信息有用得多。
            if let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: payload),
               let failure = envelope.error {
                throw GatewayClientError.refused(failure)
            }
            throw GatewayClientError.malformedResponse(detail: String(describing: error))
        }
    }
}

// MARK: - 地址

extension GatewayClient {
    /// Mac 网关的地址 —— **全 App 唯一需要改的一行**。
    ///
    /// M0 的取舍就是硬编码（Plan §4.3 Step 4）：不做设备发现、不做配置界面。
    /// 换成 `http://<Mac的主机名>.local:3081` 也行，那条路走 mDNS，IP 变了不用改。
    static let defaultBaseURL = URL(string: "http://192.168.125.23:3081")!
}

// MARK: - 请求

private struct ListSessionsRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "list-sessions"
}

/// 配对（M4）：一次性配对码换设备凭证。身份不进消息体之外的位置 ——
/// 配对码就是这条消息的载荷，走与业务同一端点。
private struct PairRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "pair"
    let code: String
}

/// 续期（M4）：设备凭证换访问凭证。
private struct RefreshRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "refresh"
    let deviceToken: String
}

private struct SnapshotRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "snapshot"
    let sessionId: String
    let since: Int
}

/// 可选字段为 `nil` 时不会出现在 JSON 里（合成实现用的是 `encodeIfPresent`），
/// 这正是协议要的形状：不传 `beforeSeq` 的意思是「从最新往回」，而不是「空值」。
private struct PageRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "page"
    let sessionId: String
    let beforeSeq: Int?
    let maxMessages: Int?
}

/// 审批应答（M5）：应答词汇表只有两键，映射在服务端完成 ——
/// `allow` → `allowed-once`（一次性，绝不推断持久授权）。
private struct ApprovalAnswerRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "approval-answer"
    let eventId: String
    let decision: String
    let answerId: String
}

/// 下发指令（M5）：`promptId` 是幂等键，服务端按它去重重复投递。
private struct SessionPromptRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "session-prompt"
    let sessionId: String
    let text: String
    let promptId: String
}

// MARK: - 响应

/// 响应信封的公共部分（协议 §三）。
///
/// 载荷字段一律声明成可选：服务端拒绝时（`ok: false`）根本不会带载荷，
/// 若声明成必选，解码会先一步失败，我们就拿不到那条有用的 `error` 了。
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
                error ?? GatewayFailure(code: "internal-error", message: "服务端拒绝了请求，但没带 error")
            )
        }
    }
}

private struct ListSessionsResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let serverTime: Double?
    let sessions: [SessionSummary]?
}

/// 配对回包（M4）：设备凭证只在这里出现一次。
private struct PairResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let deviceToken: String?
}

/// 续期回包（M4）：访问凭证与过期时刻（epoch 毫秒）。
private struct RefreshResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let accessToken: String?
    let expiresAt: Double?
}

private struct SnapshotResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let sessionId: String?
    let asOfSeq: Int?
    let hasMore: Bool?
    let events: [SessionEvent]?
}

private struct PageResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let sessionId: String?
    let pageStart: Int?
    let asOfSeq: Int?
    let hasOlder: Bool?
    let events: [SessionEvent]?
}

/// 审批应答回包（M5）：成功不带载荷，`eventId` 原样回显。
private struct ApprovalAnswerResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let eventId: String?
}

/// 下发指令回包（M5）：成功即已受理。
private struct SessionPromptResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let sessionId: String?
}

/// 只用来在解码失败时兜出信封里的错误。
private struct FailureEnvelope: Decodable {
    let error: GatewayFailure?
}

// MARK: - 快照

/// 一次快照的结果。
struct SessionSnapshot {
    let sessionId: String
    /// 本次覆盖到的位置（不含）—— 回传它就能拿到「空增量」，是水位不变式的用法。
    let asOfSeq: Int
    /// 服务端是否还有没给完的事件。为真就接着要 —— 单次响应有上限（协议 §五）。
    let hasMore: Bool
    let events: [SessionEvent]

    /// 能显示成消息的事件。其余事件（工具调用、轮次边界、用量……）不属于对话内容。
    var messages: [DisplayMessage] { events.compactMap(\.displayMessage) }
}

// MARK: - 回溯窗口

/// 一段往回读的窗口（协议 §4.3）。
///
/// 与 `SessionSnapshot` 是两个方向：快照从 `since` 往后走，窗口从某个位置往回走。
/// 打开会话时用后者取最近一段，之后用前者追新增 —— 这样客户端**不需要跨会话
/// 记住任何位置**，冷启动永远从「现在的最新一段」开始。
struct SessionPage {
    let sessionId: String
    /// 窗口首个事件的 `seq` —— 即下一次往回翻时的 `beforeSeq`。
    let pageStart: Int
    /// 窗口末尾（不含）。与 `SessionSnapshot.asOfSeq` 同义。
    let asOfSeq: Int
    /// 窗口之前还有事件吗。`false` 表示已经到日志开头。
    let hasOlder: Bool
    let events: [SessionEvent]
}

// MARK: - 失败

enum GatewayClientError: LocalizedError {
    /// 请求压根没发出去或没回来 —— 网络层的事，不是协议层的事。
    case transport(url: URL, underlying: Error)
    /// 回来了，但 HTTP 状态不是 200（协议下 400 = body 不是 JSON，413 = body 过大）。
    case badStatus(Int)
    /// 回来了、200，但不是我们能读的报文。
    case malformedResponse(detail: String)
    /// 响应的 `v` 不是本客户端认识的版本。
    case versionMismatch(Int)
    /// 服务端按信封拒绝了。这是**协议内的**结果，不是故障。
    case refused(GatewayFailure)
    /// 没有可用身份（M4）：未配对，或设备凭证已被服务端撤销。
    /// 不可重试 —— 重试要靠重新配对，不是再发一次。
    case unauthenticated

    var errorDescription: String? {
        switch self {
        case .transport(let url, let underlying):
            return Self.explain(url: url, error: underlying)

        case .badStatus(let code):
            switch code {
            case 400: return "网关说这次请求的 body 不是合法 JSON（HTTP 400）。"
            case 413: return "请求 body 超过网关的 1 MiB 上限（HTTP 413）。"
            default: return "网关回了 HTTP \(code)。"
            }

        case .malformedResponse(let detail):
            return "网关的响应读不出来：\(detail)"

        case .versionMismatch(let v):
            return "网关回的是协议 v\(v)，本客户端只会说 v\(gatewayProtocolVersion) —— 两端版本不一致。"

        case .refused(let failure):
            return failure.readableDescription

        case .unauthenticated:
            return "还没有配对，或配对已被 Mac 侧撤销 —— 请重新配对。"
        }
    }

    /// 把 `URLError` 翻译成人话 —— **Step 4 真正要撞的两个坑会在这里自己报出名字**。
    ///
    /// iOS 上有两套彼此独立的管控会拦掉到局域网的明文 HTTP，各自报不同的错：
    /// ATS 报 `-1200`，LNP 报 `NotConnectedToInternet`。改错地方都白改，
    /// 所以这里必须把它们分开说。
    private static func explain(url: URL, error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .secureConnectionFailed:
            return """
            ATS 拦下了这次明文连接（URLError -1200）。
            检查 Info.plist 里的 NSAppTransportSecurity → NSAllowsLocalNetworking。
            """
        case .notConnectedToInternet:
            return """
            本地网络隐私（LNP）拦下了这次请求（URLError -1009）。这不是「没网」——
            到「设置 → 隐私与安全性 → 本地网络」里允许本 App。
            该列表只在 App 请求过之后才出现；拒绝过就把它删掉重装，弹窗会再来一次。
            """
        case .cannotConnectToHost, .cannotFindHost:
            return """
            连不上 \(url.host ?? "?"):\(url.port.map(String.init) ?? "?")。
            三件事按序查：① Mac 上的 dsh 还在跑吗（端口 3081 有没有在听）
            ② 手机和 Mac 是同一个 Wi-Fi 吗 ③ 路由器有没有开 AP 客户端隔离。
            """
        case .timedOut:
            return "请求超时（\(Int(GatewayClient.timeout)) 秒）—— 地址可能写错了，或者中间有东西在丢包。"
        default:
            return "网络错误 \(urlError.code.rawValue)：\(urlError.localizedDescription)"
        }
    }
}
