import Foundation

/// 与 Mac 侧网关的 **op 门面 + 身份权威**：每个 op 一个方法，内部经 `GatewayTransport`
/// 发送。票从哪来、还剩多久、换不到该怎么办，全部收在这里 —— 两条通道都问它要。
///
/// **要票的唯一入口是 `ticket()`**，返回三态（`AccessTicket`）而不是 Bool：拿不到的原因分成
/// 「不会自己好」与「等一等就好」两种，其中只有后者值得重试。并发的调用共享同一个在途换票
/// 任务（单飞），所以「同时问」不会变成「同时换两张」。
///
/// **为什么要「用之前先确认」，而不是等 401 再换**：访问票只活在内存里（`CredentialStore`），
/// 冷启动后、或票过期（15 分钟）后回来，手上就是没有票。纯反应式会让每一次这样的处境都先发
/// 一发注定被拒的请求 —— 服务端记一条「没有有效票」，WS 那边还要多走一轮握手失败与退避。
/// 撞上 401 仍然会换一次并重试（那覆盖的是「本地以为有票、服务端不认」，比如 Mac 重启）；
/// 两条路分工，不是冗余。
///
/// 协议类型与语义在 `GatewayProtocol.swift`，传输机制在 `GatewayTransport.swift`。
/// `struct` 改 `class` 是因为续期单飞与已配对状态是**可变共享状态** —— 值语义会在视图间
/// 复制出各自为政的凭证；仍 `@MainActor`，因为调用方本就在主线程。
///
/// **命名按副作用分**：写操作读作祈使动词短语（`pair` / `renewTicket` /
/// `answerApproval` / `sendPrompt` / `selectModel`），读操作读作名词短语、与协议 op 同名
/// （`snapshot` / `page` / `modelCatalog`）。**已知例外**：`listSessions` 是读操作却用了
/// 动词短语 —— 改成 `sessions()` 会与属性读起来相混，故保留并在此登记。
///
/// op 对应：`pair`→`pair` · `renewTicket`→`refresh` · `listSessions`→`list-sessions` ·
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

    /// 设备凭证在手机侧的家。默认共享单例：全 App 一个身份。
    private let credentials: CredentialStore

    /// 访问票的生命周期（有没有、还剩多久、要不要换、并发谁去换）。
    ///
    /// 换票动作 `renewTicket` 在本类 —— 它要线路与协议，而票那一层不该认识这些。
    /// 接线在 `init` 末尾做而不是属性初始化式里：那个闭包要读 `self.renewTicket`，
    /// 而属性初始化式跑在 `self` 完整可用之前（编译器会拦）。
    private var tickets = TicketKeeper { _ in .retryLater }

    /// 关系是否存在（设备凭证在沙盒里）。配对成功置真，被撤销置假。
    @Published private(set) var isPaired: Bool

    init(credentials: CredentialStore? = nil) {
        // nil 默认值是为了避开跨 actor 的默认表达式求值。
        let store = credentials ?? .shared
        self.credentials = store
        self.isPaired = store.hasDeviceToken
        // 换成真的换票动作。弱引用：票那一层活不过门面，没有理由让它把门面吊住。
        tickets = TicketKeeper { [weak self] deviceToken in
            guard let self else { return .retryLater }
            return await self.renewTicket(deviceToken: deviceToken)
        }
    }

    /// 组网激活：节点验证 Running 后由 store 调用，这是端点从无到有的唯一时刻 ——
    /// HTTP 换 transport、WebSocket 换建连源，整体切到 tailnet。消息层零感知：
    /// 协议、凭证、身份状态机都不动，只换传输与地址。
    func activate(session: URLSession, baseURL: URL) {
        meshSession = session
        self.baseURL = baseURL
        transport = GatewayTransport(baseURL: baseURL, session: session)
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

    /// 还活着的 access 票；没有就是 `nil`。
    ///
    /// 流通道升级时要读它 —— 那里只有同步上下文。它**只回答现状，不会去换**：要换走 `ticket`。
    /// 必须经本类，不许直接认 `CredentialStore` —— 票在 `tickets` 里，而它可以被注入。
    func validAccessToken() -> String? {
        tickets.validToken()
    }

    /// 要一张票 —— **使用方唯一的入口**：有就立刻给，没有就去换（并发时搭同一趟）。
    ///
    /// 三种结果各有各的处置（见 `AccessTicket`）。本类只补一件票那一层不知道的事：
    /// 设备凭证在本地存着没有。
    func ticket() async -> AccessTicket {
        await tickets.ticket(deviceToken: credentials.deviceToken)
    }

    /// 换一张新的，不问手上有没有 —— 用于「服务端刚说了 401」之后：本地以为那张还有效，
    /// 读缓存只会把同一枚死票再发一遍。
    private func renewTicketNow() async -> AccessTicket {
        await tickets.renewAnyway(deviceToken: credentials.deviceToken)
    }

    /// **换票动作本身** —— 票那一层注入的就是它。线路与协议在这里，票的生命周期在那边。
    ///
    /// 三条出口对应三种处境，不合并：服务端 401 意味着关系没了（连同设备凭证一起清掉，
    /// App 回到未配对），传输失败只是这一次没成。
    private func renewTicket(deviceToken: String) async -> TicketKeeper.Renewal {
        do {
            let response: RefreshResponse = try await send(
                RefreshRequest(deviceToken: deviceToken), authenticated: false
            )
            try response.validate()
            guard let token = response.accessToken, let expiresAt = response.expiresAt else {
                // `ok: true` 却没带票：服务端的应答有问题，下一轮还会是同一个答案。
                Log.warn(Log.Module.gateway, "refresh answered without a ticket")
                return .retryLater
            }
            Log.debug(Log.Module.session, "access ticket renewed")
            return .issued(.init(token: token, expiresAt: Date(timeIntervalSince1970: expiresAt / 1000)))
        } catch GatewayClientError.unauthenticated {
            // 服务端不认这段关系了：撤销或凭证被替换。掐断本机状态 —— 重试没有意义。
            Log.warn(Log.Module.gateway, "relationship severed by server — device token cleared")
            credentials.deleteDeviceToken()
            tickets.clear()
            isPaired = false
            return .unavailable
        } catch {
            // 传输失败不是关系终结：票换不到只是暂时，退避后再试。
            Log.warn(Log.Module.session, "ticket renewal failed (transport) — will retry")
            return .retryLater
        }
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
        // 「没有有效票」，客户端再换票重试，同一件事花两次。先换再发只多一次 wait，
        // 而在票还在的场景里（15 分钟内）它一次都不等。
        let ticket = authenticated ? await self.ticket() : nil
        if let answer = try await transport.sendOnce(
            request, authorization: ticket?.token, treat401AsRefusal: !authenticated, type: Response.self
        ) {
            return answer
        }
        // 走到这里 = 业务请求被 401 拒了（pair / refresh 的 401 在 sendOnce 里
        // 自带语义上抛，不会返回 nil）。换一张票（单飞），恰好重试一次。
        //
        // 票换不到时按处境说不通的话：`.unavailable` 是「未配对 / 关系被撤销」，
        // 而 `.retryLater` 是「这次没连上」—— 后者说成前者，用户会去查一件没发生的事。
        guard authenticated else { throw GatewayClientError.unauthenticated }
        switch await renewTicketNow() {
        case .granted(let fresh):
            if let answer = try await transport.sendOnce(
                request, authorization: fresh, treat401AsRefusal: false, type: Response.self
            ) {
                return answer
            }
            throw GatewayClientError.unauthenticated
        case .unavailable:
            throw GatewayClientError.unauthenticated
        case .retryLater:
            throw GatewayClientError.transport(url: transport.baseURL, underlying: TicketUnavailable())
        }
    }
}

/// 换票没成（网络不通 / 网关不在）—— 只用来给「这次失败不是因为身份」一个可读的说法。
private struct TicketUnavailable: LocalizedError {
    var errorDescription: String? { "换取访问票失败 —— 网关没连上。" }
}
