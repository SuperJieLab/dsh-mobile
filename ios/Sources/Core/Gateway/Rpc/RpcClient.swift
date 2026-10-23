import Foundation

/// 与 Mac 侧网关的**唯一出口**：带身份地发一次请求，外加维护身份本身。
///
/// 它**不认识任何 op**。每个 op 的请求怎么拼、回包怎么读，归用到它的那个功能
/// （`Features/*/State/` 下各自的取数与下发）。这里只回答三件事：端点在哪（`activate`）、
/// 关系还在不在（`adopt` / `sever` / `isPaired`）、这一次请求带什么票且撞上 401 之后怎么办
/// （`perform`）。
///
/// **传输为什么也在这里。** 拼 `POST /rpc`、按状态码与信封判成败、把 `URLError` 原样带出 ——
/// 这些看起来是纯网络，但它们和身份是同一件事的两面：401 到底读成「换票再来」还是「关系断了」，
/// 取决于这是一次业务请求还是一次鉴权请求，而那正是 `perform` 的分支。分成两个文件时这个判断
/// 要跨文件传一个含糊的布尔（`treat401AsRefusal`），语义在传递中丢掉一半。合起来的判据是
/// **一次请求从构造到校验是一段不可分的过程**，分开后没有任何一方能单独说清 401 的含义。
///
/// **要票的唯一入口是 `ticket()`**，返回三态（`AccessTicket`）而不是 Bool：拿不到的原因分成
/// 「不会自己好」与「等一等就好」两种，其中只有后者值得重试。并发的调用共享同一个在途换票
/// 任务（单飞），所以「同时问」不会变成「同时换两张」。
///
/// **为什么要「用之前先确认」，而不是等 401 再换**：访问票只活在内存里（`TicketKeeper`），
/// 冷启动后、或票过期（15 分钟）后回来，手上就是没有票。纯反应式会让每一次这样的处境都先发
/// 一发注定被拒的请求 —— 服务端记一条「没有有效票」，WS 那边还要多走一轮握手失败与退避。
/// 撞上 401 仍然会换一次并重试（那覆盖的是「本地以为有票、服务端不认」，比如 Mac 重启）；
/// 两条路分工，不是冗余。
///
/// `struct` 改 `class` 是因为票与已配对状态是**可变共享状态** —— 值语义会在视图间复制出
/// 各自为政的凭证；仍 `@MainActor`，因为调用方本就在主线程。
@MainActor
final class RpcClient: ObservableObject {

    /// 网关端点 —— **激活前不存在**：App 在节点验证 Running 之前不持有
    /// 任何网关地址，`activate` 是它从无到有的唯一时刻。
    private(set) var baseURL: URL?

    /// 组网激活后换上的传输：激活前 = `.shared`（但端点不存在，请求不会发出）。
    /// `GatewayConnection` 的建连源每次现取，激活后下一轮连接即走隧道。
    private(set) var meshSession: URLSession = .shared

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

    /// 协议里的唯一端点 —— 所有 op 都打这一个地址，靠信封里的 `op` 分派。
    /// 多端点会把资源语义烧进 URL：客户端就得记住哪个资源走哪个地址，
    /// 而这件事协议已经从请求体里回答过了。
    nonisolated static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

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
    /// HTTP 换 session、WebSocket 换建连源，整体切到 tailnet。消息层零感知：
    /// 协议、凭证、身份状态机都不动，只换传输与地址。
    func activate(session: URLSession, baseURL: URL) {
        meshSession = session
        self.baseURL = baseURL
        // 传输切换是局域网 → tailnet 的分界点状态迁移，在此留痕。
        Log.info(Log.Module.gateway, "activated: HTTP+WS switched to \(baseURL.absoluteString)")
    }

    // MARK: - 身份

    /// **建立关系**：把一次配对换来的设备凭证收下，此后这台手机算已配对。
    ///
    /// 它只做身份的落地，不碰协议 —— 配对请求由 `Pairing` 那个功能自己发，换来的
    /// `deviceToken` 交到这里。这样「关系什么时候成立」只有一个入口，而它与下面的
    /// `sever()` 是同一对迁移的相反两半。
    func adopt(deviceToken: String) {
        credentials.saveDeviceToken(deviceToken)
        isPaired = true
        Log.info(Log.Module.gateway, "paired — device token stored")
    }

    /// **掐断关系**：服务端不认这张设备凭证了（撤销或凭证被替换）。清掉本地凭证与在手的票，
    /// App 回到未配对。
    ///
    /// 与 `adopt` 成对：两者是同一件事的两个方向，所以写在相邻的位置、名字对称。
    private func sever() {
        Log.warn(Log.Module.gateway, "relationship severed by server — device token cleared")
        credentials.deleteDeviceToken()
        tickets.clear()
        isPaired = false
    }

    /// 还活着的 access 票；没有就是 `nil`。
    ///
    /// 流通道升级时要读它 —— 那里只有同步上下文，拿不了异步的 `ticket()`。它**只回答现状，
    /// 不会去换**。
    ///
    /// **为什么这里是两行转发，而 `perform` 却直接用 `tickets`**：`perform` 就在本类里，
    /// 同一层内不必绕；而这两个方法是被 `Features/` 调的，它们是票这件事**在 Core 之外的
    /// 唯一可见面**。把 `tickets` 交出去就等于连 `renewAnyway` 一起交出去 —— 那个绕过
    /// 「先问有没有」，一次疏忽就让每个请求都换一张票。
    func validAccessToken() -> String? {
        tickets.validToken()
    }

    /// 要一张票 —— 使用方唯一的入口：有就立刻给，没有就去换（并发时搭同一趟）。
    ///
    /// 三种结果各有各的处置（见 `AccessTicket`）。本类在这两行里补一件票那一层不知道的事：
    /// 设备凭证在本地存着没有。
    ///
    /// **凭证按参传入，不让票那一层自己去取**：它现在是一台纯状态机 —— 输入只有注入的
    /// 换票动作与这一枚凭证，所以每条断言都能只给这两样。换成注入一个读取器，它每次调用就
    /// 要读一遍可变外部状态，断言也得跟着造一个。
    func ticket() async -> AccessTicket {
        await tickets.ticket(deviceToken: credentials.deviceToken)
    }

    /// **换票动作本身** —— 票那一层注入的就是它。线路与协议在这里，票的生命周期在那边。
    ///
    /// 三条出口对应三种处境，不合并：服务端 401 意味着关系没了（连同设备凭证一起清掉，
    /// App 回到未配对），传输失败只是这一次没成。
    private func renewTicket(deviceToken: String) async -> TicketKeeper.Renewal {
        do {
            let response: RefreshResponse = try await perform(
                RefreshRequest(deviceToken: deviceToken), authenticated: false
            )
            guard let token = response.accessToken, let expiresAt = response.expiresAt else {
                // `ok: true` 却没带票：服务端的应答有问题，下一轮还会是同一个答案。
                Log.warn(Log.Module.gateway, "refresh answered without a ticket")
                return .retryLater
            }
            Log.debug(Log.Module.session, "access ticket renewed")
            return .issued(
                .init(token: token, expiresAt: Date(timeIntervalSince1970: expiresAt / 1000))
            )
        } catch RpcClientError.unauthenticated {
            // 服务端不认这段关系了：撤销或凭证被替换。重试没有意义。
            sever()
            return .unavailable
        } catch {
            // 传输失败不是关系终结：票换不到只是暂时，退避后再试。
            Log.warn(Log.Module.session, "ticket renewal failed (transport) — will retry")
            return .retryLater
        }
    }

    // MARK: - 发一次请求

    /// 唯一的出网入口：带上票，发一次；被 401 拒了就换票再试恰好一次。
    ///
    /// 回包已过 `validate()` —— 版本不符、`ok` 为假都在这里抛，所以调用方拿到的
    /// 一定是一份服务端声明成功的应答。**这条校验只写在这里**：op 散到各功能之后，
    /// 少写一次不会编译报错、也不会让任何断言变红，只会静默接受一份失败回包。
    ///
    /// - Parameter authenticated: 这次请求要不要票。只有 `pair` 与换票本身是 `false`。
    ///   401 该怎么读也由它定（见 `sendOnce`）—— 两件事同源，所以只收一个参数。
    func perform<Request: Encodable, Response: GatewayResponse>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        // 未激活 = 没有地址可打：fail-fast，不猜地址。
        guard let baseURL else { throw RpcClientError.notActivated }
        // 手上有票才发。没有票照样发出去，换来的是一次注定被拒的往返 —— 服务端记一条
        // 「没有有效票」，客户端再换票重试，同一件事花两次。先换再发只多一次 wait，
        // 而在票还在的场景里（15 分钟内）它一次都不等。
        let ticket = authenticated ? await self.ticket() : nil
        // 标注类型：`sendOnce` 的返回只在这里判空，编译器无从推它的泛型参数。
        let first: Response? = try await sendOnce(
            request, at: baseURL, authorization: ticket?.token, treat401AsRefusal: !authenticated
        )
        if let first { return first }
        // 走到这里 = 业务请求被 401 拒了（鉴权请求的 401 在 `sendOnce` 里自带语义上抛，
        // 不会返回 nil）。换一张票（单飞），恰好重试一次。
        //
        // 票换不到时按处境说不通的话：`.unavailable` 是「未配对 / 关系被撤销」，
        // 而 `.retryLater` 是「这次没连上」—— 后者说成前者，用户会去查一件没发生的事。
        guard authenticated else { throw RpcClientError.unauthenticated }
        // 调 `renewAnyway` 而不是 `ticket()`：本地那张被服务端否认了，读缓存只会把同一枚
        // 死票再发一遍。设备凭证在这里现取 —— 它是这一刻的事实，不缓存在票那一层。
        switch await tickets.renewAnyway(deviceToken: credentials.deviceToken) {
        case .granted(let fresh):
            let retried: Response? = try await sendOnce(
                request, at: baseURL, authorization: fresh, treat401AsRefusal: false
            )
            if let retried { return retried }
            throw RpcClientError.unauthenticated
        case .unavailable:
            throw RpcClientError.unauthenticated
        case .retryLater:
            throw RpcClientError.transport(url: baseURL, underlying: TicketUnavailable())
        }
    }

    /// 发一次，不解身份语义，并在解码后校验信封。
    ///
    /// 返回 `nil` 只表示**业务请求被 401 拒了**（换票再来一次的号）。配对与换票的 401 是
    /// **定论**，必须读出信封里的原因上抛：配对码不对就要说配对码不对。
    private func sendOnce<Request: Encodable, Response: GatewayResponse>(
        _ request: Request,
        at baseURL: URL,
        authorization: String?,
        treat401AsRefusal: Bool
    ) async throws -> Response? {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(Self.rpcPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 身份只走传输头，不进消息体：消息体的每一个字段都是协议的一部分，
        // 凭证放进去会让它出现在日志、重放与错误回显里。
        if let authorization {
            urlRequest.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let payload: Data
        let urlResponse: URLResponse
        do {
            (payload, urlResponse) = try await meshSession.data(for: urlRequest)
        } catch {
            // 请求没发出去或没回来：读链路唯一的服务端外故障点，必须留痕。
            Log.warn(
                Log.Module.gateway,
                "transport: \(error.localizedDescription) (base=\(baseURL.host ?? "?"))"
            )
            throw RpcClientError.transport(url: urlRequest.url ?? baseURL, underlying: error)
        }

        if let http = urlResponse as? HTTPURLResponse {
            guard http.statusCode != 401 else {
                // 业务请求的 401 是「换个票再来」的信号，返回 nil 交外层换票重试；鉴权请求
                // 的 401 自带语义，必须读出信封上抛。
                guard treat401AsRefusal else {
                    Log.debug(Log.Module.gateway, "401 on business op — renewing ticket")
                    return nil
                }
                if let failure = envelopeFailure(in: payload) {
                    if failure.code == GatewayErrorCode.unauthenticated.rawValue {
                        Log.info(
                            Log.Module.gateway,
                            "auth op refused: \(failure.code) — \(failure.message)"
                        )
                        throw RpcClientError.unauthenticated
                    }
                    throw RpcClientError.refused(failure)
                }
                throw RpcClientError.unauthenticated
            }
            if http.statusCode != 200 {
                Log.warn(Log.Module.gateway, "HTTP \(http.statusCode) from \(baseURL.host ?? "?")")
                throw RpcClientError.badStatus(http.statusCode)
            }
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            // 解不出来时先看看能不能读出信封里的 error —— 服务端的拒绝
            // 比解码器的报错信息有用得多。
            if let failure = envelopeFailure(in: payload) {
                Log.warn(Log.Module.gateway, "op refused: \(failure.code) — \(failure.message)")
                throw RpcClientError.refused(failure)
            }
            Log.warn(Log.Module.gateway, "malformed response: \(String(describing: error))")
            throw RpcClientError.malformedResponse(detail: String(describing: error))
        }
        try response.validate()
        return response
    }
}

/// 换票没成（网络不通 / 网关不在）—— 只用来给「这次失败不是因为身份」一个可读的说法。
private struct TicketUnavailable: LocalizedError {
    var errorDescription: String? { "换取访问票失败 —— 网关没连上。" }
}

/// 只用来在解码失败时兜出信封里的错误。
private struct FailureEnvelope: Decodable {
    let error: GatewayFailure?
}

/// 信封里的 error（没有就 nil）。
private func envelopeFailure(in payload: Data) -> GatewayFailure? {
    (try? JSONDecoder().decode(FailureEnvelope.self, from: payload))?.error
}
