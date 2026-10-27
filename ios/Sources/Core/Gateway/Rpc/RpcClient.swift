import Foundation

/// 与 Mac 侧网关的**请求门面**：带票地发一次请求，并维护票的生命周期。
///
/// 它**不认识任何 op**。每个 op 的请求怎么拼、回包怎么读，归用到它的那个功能
/// （`Features/*/State/` 下各自的取数与下发）。这里只回答两件事：这一次请求带什么票
/// （`ticket` 换、`tickets.validToken` 读）、撞上 401 之后怎么办（`perform`）。
///
/// **身份不在这里。** 「关系还在不在」的真值是 `CredentialStore.deviceToken` —— 它自己
/// 可观察，所以没有第二份副本要同步，也没有一个「客户端认为的身份」要与它对齐。本类只在
/// 需要凭证时去问（换票的入参、断关系时清掉它），不持有任何身份状态。
///
/// **发字节那半不在这里**，在 `HttpTransport` —— 它不认识票，于是「换票那一发不带票」
/// 不是一条纪律，而是结构上拿不到票源：票闸在 `perform`，裸发层没有它。
/// 401 的两种读法（「换票再来」与「关系断了」）仍只在本类判：裸发层只负责把
/// 「这是一次鉴权请求」这个**事实**传上来（`treat401AsRefusal`），怎么处置由这里决定。
///
/// **票面经 `tickets` 直接对外**（`validToken` 读现状、`ticket` 换一张）。只有 `ticket()`
/// 留在本类：它是**组合**动作 —— 把本机凭证接给票层，而凭证只有这里同时拿得到。
/// 读现状不包方法，直接用 `tickets.validToken()` —— 那是一条纯转发，包一层只是多一个名字。
///
/// **为什么要「用之前先确认」，而不是等 401 再换**：访问票只活在内存里（`TicketKeeper`），
/// 冷启动后、或票过期（15 分钟）后回来，手上就是没有票。纯反应式会让每一次这样的处境都先发
/// 一发注定被拒的请求 —— 服务端记一条「没有有效票」，WS 那边还要多走一轮握手失败与退避。
/// 撞上 401 仍然会换一次并重试（那覆盖的是「本地以为有票、服务端不认」，比如 Mac 重启）；
/// 两条路分工，不是冗余。
///
/// `struct` 改 `class` 是因为票与凭证是**可变共享状态** —— 值语义会在视图间复制出
/// 各自为政的副本；仍 `@MainActor`，因为调用方本就在主线程。
///
/// **不带观察**：本类没有可观察成员（全部是 `let` 或 `lazy`）。要观察身份，观察
/// `CredentialStore`；它才是那个事实的出处。
@MainActor
final class RpcClient {

    /// 往哪打：组网域产出的地址，本类只**问**它，不存副本。`nil` = 隧道没通。
    private let baseURLProvider: () -> URL?
    /// 裸发层 —— 票闸在下面，它不认识票。
    private let http: HttpTransport

    /// 设备凭证在手机侧的家。它自己可观察 —— 本类只是读者之一。
    private let credentials: CredentialStore

    /// 访问票的生命周期（有没有、还剩多久、要不要换、并发谁去换）。
    ///
    /// 换票动作 `renewTicket` 在本类 —— 它要线路与协议，而票那一层不该认识这些。
    ///
    /// **为什么是 `lazy`**：构造它要一个读 `self.renewTicket` 的闭包，而 Swift 要求
    /// 闭包捕获 `self` 时所有存储属性已初始化 —— 包括这一条自己。这是语言层的环。
    /// `lazy` 是唯一的直说方式：**一个定义、一个构造点**，首次用时才求值，那时 `self`
    /// 已完整。它不同于「先塞一个假值、稍后再替换」—— 后者存在一个「票层是假的」的阶段，
    /// 而这里不存在那个阶段。
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
    /// 两条触发路径，动作相同而原因不同，所以收一个 `reason`（日志要分得清 —— 排障时
    /// 「用户自己点的」与「被服务端踢下线」是完全不同的两件事）：
    /// - 服务端撤销：换票被 401 拒（见 `renewTicket`）
    /// - 用户主动解除：配对页那个按钮
    ///
    /// **两半必须一起做**，这是本方法存在的唯一理由：只删凭证不清票，会留下「有票没凭证」
    /// 的窗口 —— 请求带着未过期的票照常成功，而用户以为关系已经解除。这两半分别住在
    /// `CredentialStore` 与 `TicketKeeper`，只有本类同时持有两者。
    ///
    /// 不叫 `sever`：「切断」描述的是服务端那一侧的动作，用户主动解除那一支说不通。
    func discardIdentity(reason: Reason) {
        Log.warn(Log.Module.gateway, "identity discarded (\(reason.logWord)) — token and ticket cleared")
        credentials.deleteDeviceToken()
        tickets.clear()
    }

    /// 关系为什么结束。两个取值对应两条触发路径，只为日志区分。
    enum Reason {
        /// 服务端不认这段关系了（撤销 / 凭证被替换）。
        case revokedByServer
        /// 用户在配对页主动解除。
        case userRequested

        var logWord: String {
            switch self {
            case .revokedByServer: return "by server"
            case .userRequested: return "by user"
            }
        }
    }

    // MARK: - 票

    /// 换一张票 —— 使用方的入口：有就立刻给，没有就去换（并发时搭同一趟）。
    ///
    /// 三种结果各有各的处置（见 `AccessTicket`）。本类在这两行里补一件票那一层不知道的事：
    /// 设备凭证在本地存着没有。
    ///
    /// **凭证按参传入，不让票那一层自己去取**：它现在是一台纯状态机 —— 输入只有注入的
    /// 换票动作与这一枚凭证，所以每条断言都能只给这两样。换成注入一个读取器，它每次调用就
    /// 要读一遍可变外部状态，断言也得跟着造一个。
    ///
    /// **为什么只有这个方法留在本类**：换票是**组合** —— 把凭证接给票层，而两者只有这里同时
    /// 拿得到。只读现状（`tickets.validToken()`）不必包一层，那只是多一个名字。
    func ticket() async -> AccessTicket {
        await tickets.ticket(deviceToken: credentials.deviceToken)
    }

    /// **换票动作本身** —— 票那一层注入的就是它。线路与协议在这里，票的生命周期在那边。
    ///
    /// 三条出口对应三种处境，不合并：服务端 401 意味着关系没了（连同设备凭证一起清掉，
    /// App 回到未配对），传输失败只是这一次没成。
    ///
    /// **它直接走裸发层，不走 `perform`** —— 这不是省一层，是这道闸的落点：
    /// `perform` 会先问票层要票，而此刻票层正等在**这次换票**上 ⇒ 问它就是等自己。
    /// 走裸发层则结构上拿不到票（`authorization` 传 nil），那条回环不存在。
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

    /// 唯一的出网入口：带上票，发一次；被 401 拒了就换票再试恰好一次。
    ///
    /// 回包已过 `validate()` —— 版本不符、`ok` 为假都在这里抛，所以调用方拿到的
    /// 一定是一份服务端声明成功的应答。**这条校验只写在这里**：op 散到各功能之后，
    /// 少写一次不会编译报错、也不会让任何断言变红，只会静默接受一份失败回包。
    ///
    /// - Parameter authenticated: 这次请求要不要票。**配对是唯一的 `false`** ——
    ///   换票自己不走这条路（它直接经 `HttpTransport.send`，结构上拿不到票）。
    ///   401 该怎么读也由它定（见 `HttpTransport.send`）—— 两件事同源，所以只收一个参数。
    func perform<Request: Encodable, Response: GatewayResponse>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        // 隧道没通 = 没有地址可打：fail-fast，不猜地址。
        guard let baseURL = baseURLProvider() else { throw RpcClientError.notActivated }
        // 手上有票才发。没有票照样发出去，换来的是一次注定被拒的往返 —— 服务端记一条
        // 「没有有效票」，客户端再换票重试，同一件事花两次。先换再发只多一次 wait，
        // 而在票还在的场景里（15 分钟内）它一次都不等。
        let ticket = authenticated ? await self.ticket() : nil
        // 标注类型：`send` 的返回只在这里判空，编译器无从推它的泛型参数。
        let first: Response? = try await http.send(
            request, authorization: ticket?.token, treat401AsRefusal: !authenticated
        )
        if let first { return first }
        // 走到这里 = 业务请求被 401 拒了（鉴权请求的 401 在 `send` 里自带语义上抛，
        // 不会返回 nil）。换一张票（单飞），恰好重试一次。
        //
        // 票换不到时按处境说不通的话：`.unavailable` 是「未配对 / 关系被撤销」，
        // 而 `.retryLater` 是「这次没连上」—— 后者说成前者，用户会去查一件没发生的事。
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

