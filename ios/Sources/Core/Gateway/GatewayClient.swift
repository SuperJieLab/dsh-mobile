import Foundation

/// 与 Mac 侧网关的 **op 门面 + 身份状态机**：每个 op 一个方法，内部经
/// `GatewayTransport` 发送；身份是这里的状态 —— 401 时用设备凭证**静默续期一次再重试**，
/// 续期单飞保证并发撞 401 的请求共享同一张新票。
///
/// 协议的类型与语义都在 `GatewayProtocol.swift`，传输机制在 `GatewayTransport.swift`，
/// SwiftUI 在这里没有位置。`struct` 改 `class` 是因为续期单飞与已配对状态是**可变共享
/// 状态**，值语义会在视图间复制出各自为政的凭证；仍 `@MainActor`，因为所有调用方本就在主线程。
@MainActor
final class GatewayClient: ObservableObject {
    private(set) var baseURL: URL

    /// 组网后的承载：未激活 = `.shared`（局域网直连）。
    /// 与 transport 分开存：`FollowClient` 的建连源每次现取，激活后下一轮连接即走隧道。
    private(set) var meshSession: URLSession = .shared

    private var transport: GatewayTransport

    /// 三张票在手机侧的家。与 transport 共持同一份；默认共享单例：全 App 一个身份。
    private let credentials: CredentialStore

    /// 续期单飞：同一时刻只允许一个 `refresh` 在途（401 竞态）。
    /// 并发撞上 401 的请求都等这一张新票，然后各自重试一次。
    private var refreshTask: Task<Bool, Never>?

    /// 关系是否存在（设备凭证在沙盒里）。配对成功置真，被撤销置假。
    @Published private(set) var isPaired: Bool

    init(baseURL: URL, credentials: CredentialStore? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        // nil 默认值是为了避开跨 actor 的默认表达式求值。
        self.credentials = credentials ?? .shared
        self.transport = GatewayTransport(baseURL: baseURL, credentials: self.credentials, session: session)
        self.isPaired = self.credentials.hasDeviceToken
    }

    /// 组网激活：节点 Running 后由根部调用 —— HTTP 换 transport、
    /// WebSocket 换建连源，整体切到 tailnet。消息层零感知：协议、凭证、
    /// 身份状态机都不动，只换承载与地址。
    func activate(session: URLSession, baseURL: URL) {
        meshSession = session
        self.baseURL = baseURL
        transport = GatewayTransport(baseURL: baseURL, credentials: credentials, session: session)
        // 承载切换是局域网 → tailnet 的分界点状态迁移，在此留痕。
        Log.info(Log.Module.gateway, "activated: HTTP+WS switched to \(baseURL.absoluteString)")
    }

    /// 配对：用 Mac 屏幕上的一次性配对码换设备凭证。成功即建立关系；失败文案来自服务端。
    func pair(code: String) async throws {
        let response: PairResponse = try await send(PairRequest(code: code), authenticated: false)
        try response.validate()
        guard let deviceToken = response.deviceToken else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里没有 deviceToken")
        }
        credentials.saveDeviceToken(deviceToken)
        isPaired = true
        Log.info(Log.Module.gateway, "paired — device token stored")
    }

    /// 用设备凭证换一张新 access。返回 false 表示关系已被服务端掐断（401）—— 此时
    /// 清掉本机凭证，App 回到未配对状态。单飞：撞车的调用共享同一个在途任务，不叠加请求。
    func refreshAccess() async -> Bool {
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
                Log.debug(Log.Module.session, "access ticket refreshed")
                return true
            } catch GatewayClientError.unauthenticated {
                // 服务端不认这段关系了：撤销或凭证被替换。掐断本机状态。
                Log.warn(Log.Module.gateway, "relationship severed by server — device token cleared")
                self.credentials.deleteDeviceToken()
                self.isPaired = false
                return false
            } catch {
                // 传输失败不是关系终结：票换不到只是暂时，下次再试。
                Log.warn(Log.Module.session, "refresh failed (transport) — retrying next 401")
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
            asOfSeq: asOfSeq,
            // 缺省 `false`：不带这个字段的是旧服务端，它只会一次给完。
            hasMore: response.hasMore ?? false,
            events: events,
            // 基线：服务端「不知道」时整个缺省 —— 客户端退到目录默认，不猜。
            model: response.model
        )
    }

    /// 拉一段回溯窗口 —— 打开会话与往回翻都用它。
    /// - Parameters:
    ///   - beforeSeq: 窗口上界（不含）。不传表示「从最新往回」（打开会话）；
    ///   往回翻时传上一次的 `pageStart`。
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
            pageStart: pageStart,
            asOfSeq: asOfSeq,
            hasOlder: hasOlder,
            events: events
        )
    }

    // MARK: - 两个写 op

    /// 应答一条审批。`ok` 只意味着**已投递**，权威结果以流里的 `approval/decided` 为准。
    /// 失败如实上抛：`unknown-approval` 表示这条审批已经不在了。
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

    // MARK: - 模型选择

    /// 拉模型目录：打开选择器时现拉一次，不订阅刷新 —— 重开即新。
    func modelCatalog() async throws -> ModelCatalog {
        let response: ModelCatalogResponse = try await send(ModelCatalogRequest())
        try response.validate()
        return ModelCatalog(default: response.default, groups: response.groups, failures: response.failures)
    }

    /// 安装一次会话级选择。`ok` = **已安装给下一轮**，不是「已生效」——
    /// 生效的证据是流里的 `model/selection` 与随后的 `request/header`。
    @discardableResult
    func modelSelect(sessionId: String, selection: ModelSelection) async throws -> ModelSelection {
        let response: ModelSelectResponse = try await send(
            ModelSelectRequest(
                sessionId: sessionId,
                provider: selection.provider,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort
            )
        )
        try response.validate()
        guard let selected = response.selected else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里没有 selected")
        }
        return selected
    }

    // MARK: - 发一次请求（带身份，续期恰好重试一次）

    private func send<Request: Encodable, Response: Decodable>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        if let answer = try await transport.sendOnce(request, authenticated: authenticated, type: Response.self) {
            return answer
        }
        // 走到这里 = 业务请求被 401 拒了（pair / refresh 的 401 在 sendOnce 里
        // 自带语义上抛，不会返回 nil）。换一张票（单飞），恰好重试一次。
        guard authenticated, await refreshAccess() else {
            throw GatewayClientError.unauthenticated
        }
        if let answer = try await transport.sendOnce(request, authenticated: authenticated, type: Response.self) {
            return answer
        }
        throw GatewayClientError.unauthenticated
    }
}

// MARK: - 地址

extension GatewayClient {
    /// 局域网兜底地址 —— 组网配置（`MeshConfig`）缺失时的启动兜底，也是
    /// 「全 App 唯一需要改的一行」。生产地址走 tailnet（`MeshConfig.gatewayDefault`）；
    /// 换成 `http://<Mac的主机名>.local:3081` 走 mDNS 也行。
    static let defaultBaseURL = URL(string: "http://192.168.125.23:3081")!
}
