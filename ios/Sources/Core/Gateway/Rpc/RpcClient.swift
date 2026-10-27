import Foundation

/// 与 Mac 侧网关的**请求门面**：带票发一次，并维护票的生命周期。它**不认识任何 op** ——
/// 请求怎么拼、回包怎么读归各功能（`Features/*/State/`）。
///
/// **身份不在这里。** 「关系还在不在」的真值是 `CredentialStore.deviceToken`，它自己可
/// 观察。本类只在需要凭证时去问（换票的入参、断关系时清掉它），不持有任何身份状态。
///
/// **发字节那半在 `HttpTransport`**，它不认识票 —— 于是「换票那一发不带票」不是纪律，而是
/// 结构上拿不到票源。401 的两种读法（「换票再来」与「关系断了」）仍只在本类判：裸发层只
/// 把「这是一次鉴权请求」这个事实传上来。
///
/// **用之前先确认，不等 401 再换**：票只活在内存里，冷启动后或过期后手上就是没有。纯反应式
/// 会让每次这样的处境都先发一发注定被拒的请求。撞上 401 仍会换一次并重试（覆盖「本地以为
/// 有票、服务端不认」，如 Mac 重启）；两条路分工，不是冗余。
///
/// `class` 而非 `struct`：票与凭证是可变的共享状态，值语义会在视图间复制出各自为政的副本。
@MainActor
final class RpcClient {

    /// 往哪打：组网域产出的地址，本类只**问**它，不存副本。`nil` = 隧道没通。
    private let baseURLProvider: () -> URL?
    /// 裸发层 —— 票闸在下面，它不认识票。
    private let http: HttpTransport

    private let credentials: CredentialStore

    /// 票的生命周期。换票动作 `renewTicket` 在本类 —— 它要线路与协议，而票那一层不该认识。
    ///
    /// **必须 `lazy`**：构造它要一个读 `self.renewTicket` 的闭包，而 Swift 要求闭包捕获
    /// `self` 时所有存储属性已初始化 —— 包括这一条自己。语言层的环，`lazy` 是唯一的直说
    /// 方式（不同于「先塞假值、稍后替换」：那种写法存在「票层是假的」的阶段）。
    private(set) lazy var tickets = TicketKeeper { [weak self] deviceToken in
        guard let self else { return .retryLater }
        return await self.renewTicket(deviceToken: deviceToken)
    }

    init(session: @escaping () -> URLSession,
         baseURL: @escaping () -> URL?,
         credentials: CredentialStore? = nil) {
        // nil 默认值是为了避开跨 actor 的默认表达式求值。
        self.baseURLProvider = baseURL
        self.http = HttpTransport(session: session, baseURL: baseURL)
        self.credentials = credentials ?? .shared
    }

    // MARK: - 关系结束

    /// **关系结束了**：本机不再持有这张凭证，手上的票也一并作废。
    ///
    /// **两半必须一起做** —— 这是本方法存在的理由：只删凭证不清票会留下「有票没凭证」的
    /// 窗口，请求带着未过期的票照常成功，而用户以为关系已经解除。这两半分别住在
    /// `CredentialStore` 与 `TicketKeeper`，只有本类同时持有。
    ///
    /// 收 `reason` 只为日志分得清：「用户自己点的」与「被服务端踢下线」排障时完全不同。
    func discardIdentity(reason: Reason) {
        Log.warn(Log.Module.gateway, "identity discarded (\(reason.logWord)) — token and ticket cleared")
        credentials.deleteDeviceToken()
        tickets.clear()
    }

    enum Reason {
        case revokedByServer
        case userRequested

        var logWord: String {
            switch self {
            case .revokedByServer: return "by server"
            case .userRequested: return "by user"
            }
        }
    }

    // MARK: - 票

    /// 换一张票：有就立刻给，没有就去换（并发时搭同一趟）。三种结果各有各的处置，
    /// 见 `AccessTicket`。
    ///
    /// **凭证按参传入，不让票那一层自己去取**：它是一台纯状态机，输入只有换票动作与这一枚
    /// 凭证，所以每条断言只给这两样。换成注入读取器，它每次调用都要读可变外部状态。
    ///
    /// **只有这个方法留在本类**：换票是**组合**（把凭证接给票层，而两者只有这里同时拿得到）。
    /// 只读现状直接用 `tickets.validToken()` —— 包一层只是多一个名字。
    func ticket() async -> AccessTicket {
        await tickets.ticket(deviceToken: credentials.deviceToken)
    }

    /// **换票动作本身** —— 票那一层注入的就是它。线路与协议在这里，票的生命周期在那边。
    ///
    /// **直接走裸发层，不走 `perform`** —— 这是死锁的落点：`perform` 会先问票层要票，而此刻
    /// 票层正等在这次换票上 ⇒ 问它就是等自己。走裸发层则结构上拿不到票（`authorization`
    /// 传 nil），那条回环不存在。
    private func renewTicket(deviceToken: String) async -> TicketKeeper.Renewal {
        do {
            let response: RefreshResponse? = try await http.send(
                RefreshRequest(deviceToken: deviceToken),
                authorization: nil,
                treat401AsRefusal: true
            )
            guard let response else {
                // 鉴权请求的 401 在裸发层里自带语义上抛，不会返回 nil —— 真到了这里说明
                // 有人在裸发层改了那条分支。按「换不到」处理，不静默。
                Log.warn(Log.Module.gateway, "refresh returned without a verdict")
                return .retryLater
            }
            guard let token = response.accessToken, let expiresAt = response.expiresAt else {
                // `ok: true` 却没带票：服务端的应答有问题，下一轮还会是同一个答案。
                Log.warn(Log.Module.gateway, "refresh answered without a ticket")
                return .retryLater
            }
            Log.debug(Log.Module.session, "access ticket renewed")
            return .issued(
                .init(token: token, expiresAt: epochMilliseconds(expiresAt))
            )
        } catch RpcClientError.unauthenticated {
            // 服务端不认这段关系了：撤销或凭证被替换。重试没有意义。
            discardIdentity(reason: .revokedByServer)
            return .unavailable
        } catch {
            // 传输失败不是关系终结：票换不到只是暂时，退避后再试。
            Log.warn(Log.Module.session, "ticket renewal failed (transport) — will retry")
            return .retryLater
        }
    }

    // MARK: - 发一次请求

    /// 唯一的出网入口：带上票发一次，被 401 拒了就换票再试恰好一次。
    ///
    /// 回包已过 `validate()` —— 版本不符、`ok` 为假都在这里抛。**这条校验只写在这里**：
    /// op 散到各功能之后，少写一次既不会编译报错、也不会让断言变红，只会静默接受一份失败回包。
    ///
    /// - Parameter authenticated: 要不要票，**配对是唯一的 `false`**；401 该怎么读也由它定
    ///   （见 `HttpTransport.send`）—— 两件事同源，所以只收一个参数。
    func perform<Request: Encodable, Response: GatewayResponse>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        // 隧道没通 = 没有地址可打：fail-fast，不猜地址。
        guard let baseURL = baseURLProvider() else { throw RpcClientError.notActivated }
        // 先换再发：票还在（15 分钟内）时一次都不等，没票时才付那一次 wait —— 比「先发
        // 一发注定被拒的」少一半往返。
        let ticket = authenticated ? await self.ticket() : nil
        // 标注类型：`send` 的返回只在这里判空，编译器无从推它的泛型参数。
        let first: Response? = try await http.send(
            request, authorization: ticket?.token, treat401AsRefusal: !authenticated
        )
        if let first { return first }
        // 走到这里 = 业务请求被 401 拒了。换一张票（单飞），恰好重试一次。
        //
        // 换不到时按处境说不同的话：`.unavailable` 是「未配对 / 关系被撤销」，
        // `.retryLater` 是「这次没连上」—— 后者说成前者，用户会去查一件没发生的事。
        guard authenticated else { throw RpcClientError.unauthenticated }
        // 调 `renewAnyway` 而不是 `ticket()`：本地那张被服务端否认了，读缓存只会把同一枚
        // 死票再发一遍。设备凭证在这里现取 —— 它是这一刻的事实，不缓存在票那一层。
        switch await tickets.renewAnyway(deviceToken: credentials.deviceToken) {
        case .granted(let fresh):
            let retried: Response? = try await http.send(
                request, authorization: fresh, treat401AsRefusal: false
            )
            if let retried { return retried }
            throw RpcClientError.unauthenticated
        case .unavailable:
            throw RpcClientError.unauthenticated
        case .retryLater:
            throw RpcClientError.transport(url: baseURL, underlying: TicketUnavailable())
        }
    }

}

/// 换票没成（网络不通 / 网关不在）—— 只用来给「这次失败不是因为身份」一个可读的说法。
private struct TicketUnavailable: LocalizedError {
    var errorDescription: String? { "换取访问票失败 —— 网关没连上。" }
}

