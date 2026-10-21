import Foundation

/// 与 Mac 侧网关的 **op 门面 + 身份状态机**：每个 op 一个方法，内部经 `GatewayTransport`
/// 发送；身份是这里的状态 —— 用之前先确认手上有票（没有就换一张），真的撞上 401 再**静默续期
/// 一次并重试**。续期单飞让并发撞 401 的请求共享同一张新票。
///
/// **为什么要「用之前先确认」**：访问票只活在内存里（`CredentialStore`），冷启动后、或票过期
/// （15 分钟）后回来，手上就是没有票。纯反应式（等 401 再续）会让每一次这样的处境都先发一发
/// 注定被拒的请求 —— 服务端记一条「没有有效票」，WS 那边还要多走一轮握手失败与退避。那串日志
/// 与那几百毫秒的空屏都是这一步的自证，而不是网出了问题。
///
/// 协议类型与语义在 `GatewayProtocol.swift`，传输机制在 `GatewayTransport.swift`。
/// `struct` 改 `class` 是因为续期单飞与已配对状态是**可变共享状态** —— 值语义会在视图间
/// 复制出各自为政的凭证；仍 `@MainActor`，因为调用方本就在主线程。
///
/// **命名按副作用分**：写操作读作祈使动词短语（`pair` / `refreshAccess` /
/// `answerApproval` / `sendPrompt` / `selectModel`），读操作读作名词短语、与协议 op 同名
/// （`snapshot` / `page` / `modelCatalog`）。**已知例外**：`listSessions` 是读操作却用了
/// 动词短语 —— 改成 `sessions()` 会与属性读起来相混，故保留并在此登记。
///
/// op 对应：`pair`→`pair` · `refreshAccess`→`refresh` · `listSessions`→`list-sessions` ·
/// `snapshot`→`snapshot` · `page`→`page` · `answerApproval`→`approval-answer` ·
/// `sendPrompt`→`session-prompt` · `modelCatalog`→`model-catalog` ·
/// `selectModel`→`model-select`。
@MainActor
final class GatewayClient: ObservableObject {
    /// 网关端点 —— **激活前不存在**：App 在节点验证 Running 之前不持有
    /// 任何网关地址，`activate` 是它从无到有的唯一时刻。
    private(set) var baseURL: URL?

    /// 组网激活后的传输：激活前 = `.shared`（但端点不存在，请求不会发出）。
    /// 与 transport 分开存：`FollowClient` 的建连源每次现取，激活后下一轮连接即走隧道。
    private(set) var meshSession: URLSession = .shared

    private var transport: GatewayTransport?

    /// 三张票在手机侧的家。与 transport 共持同一份；默认共享单例：全 App 一个身份。
    private let credentials: CredentialStore

    /// 续期单飞：同一时刻只允许一个 `refresh` 在途（401 竞态）。
    /// 并发撞上 401 的请求都等这一张新票，然后各自重试一次。
    private var refreshTask: Task<Bool, Never>?

    /// 关系是否存在（设备凭证在沙盒里）。配对成功置真，被撤销置假。
    @Published private(set) var isPaired: Bool

    init(credentials: CredentialStore? = nil) {
        // nil 默认值是为了避开跨 actor 的默认表达式求值。
        self.credentials = credentials ?? .shared
        self.isPaired = self.credentials.hasDeviceToken
    }

    /// 组网激活：节点验证 Running 后由 store 调用，这是端点从无到有的唯一时刻 ——
    /// HTTP 换 transport、WebSocket 换建连源，整体切到 tailnet。消息层零感知：
    /// 协议、凭证、身份状态机都不动，只换传输与地址。
    func activate(session: URLSession, baseURL: URL) {
        meshSession = session
        self.baseURL = baseURL
        transport = GatewayTransport(baseURL: baseURL, credentials: credentials, session: session)
        // 传输切换是局域网 → tailnet 的分界点状态迁移，在此留痕。
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

    /// 还活着的 access 票；没有就是 `nil`。过期的票等价于没有票，调用方走续期。
    ///
    /// 流通道升级时要读它。**必须经这里，不许直接认 `CredentialStore.shared`** ——
    /// 本类的 `credentials` 可注入，WS 与 HTTP 若各取各的，换掉注入实例之后两条路径
    /// 会各自为政，而那种不一致在运行时看不出来（默认都指向 `.shared`）。
    func validAccessToken() -> String? {
        credentials.validAccessToken()
    }

    /// 保证手上有一张还活着的票 —— **用之前先调它**：有票就什么都不做，没票就换一张。
    ///
    /// 幂等且单飞：进屏那一拍 HTTP 与 WS 两条路会同时问到它，只该发出一次 `refresh`。
    /// 返回 false 表示换不到（未配对、或关系已被服务端掐断），调用方照常走自己的失败路径 ——
    /// 这里不抛，因为「没有票」在 HTTP 那边本来就是可重试的一步。
    @discardableResult
    func ensureAccess() async -> Bool {
        if credentials.validAccessToken() != nil { return true }
        guard isPaired else { return false }
        return await refreshAccess()
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
        // clock 采样：服务端时钟与本地收到时刻的一对。两端 offset 由这一对估出来，
        // 才能修正跨机的 t3 段与端到端 —— 直接相减会把这个 offset 算进延迟里。
        if let serverTime = response.serverTime {
            Log.perf(Log.Module.gateway, PerfRecord(
                seg: .clock, t: PerfRecord.nowMs(),
                fields: ["serverTime": .number(serverTime)]
            ))
        }
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
    /// - beforeSeq: 窗口上界（不含）。不传表示「从最新往回」（打开会话）；
    /// 往回翻时传上一次的 `pageStart`。
    /// - maxMessages: 最多取多少条消息。不传就用服务端的默认值。
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
    func selectModel(sessionId: String, selection: ModelSelection) async throws -> ModelSelection {
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

    // MARK: - 命令

    /// 列该会话此刻能用的命令。**每次打开面板都拉**：命令集是 per-agent 的，
    /// 随插件装卸与作用域变，不缓存成常量。
    func commandCatalog(sessionId: String) async throws -> [CommandInfo] {
        let response: CommandCatalogResponse = try await send(CommandCatalogRequest(sessionId: sessionId))
        try response.validate()
        return response.commands ?? []
    }

    /// 执行一整行命令。`ok` = **已受理**，结果从订阅流里的
    /// `command/run` / `command/done` 来 —— 这个回包不带执行结果。
    @discardableResult
    func executeCommand(sessionId: String, line: String) async throws -> String {
        let response: CommandExecuteResponse = try await send(
            CommandExecuteRequest(sessionId: sessionId, line: line)
        )
        try response.validate()
        guard let commandId = response.commandId else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里没有 commandId")
        }
        return commandId
    }

    // MARK: - 发一次请求（带身份，续期恰好重试一次）

    private func send<Request: Encodable, Response: Decodable>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        // 未激活 = 没有地址可打：fail-fast，不猜地址。
        guard let transport else { throw GatewayClientError.notActivated }
        // 手上有票才发。没有票照样发出去，换来的是一次注定被拒的往返 —— 服务端记一条
        // 「没有有效票」，客户端再续期重试，同一件事花两次。先换再发只多一次 wait，
        // 而在票还在的场景里（15 分钟内）它一次都不等。
        if authenticated { await ensureAccess() }
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
