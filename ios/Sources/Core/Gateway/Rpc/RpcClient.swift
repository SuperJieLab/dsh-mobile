import Foundation

/// 与 Mac 侧网关的**身份门面**：带票地发一次请求，外加维护身份本身。
///
/// 它**不认识任何 op**。每个 op 的请求怎么拼、回包怎么读，归用到它的那个功能
/// （`Features/*/State/` 下各自的取数与下发）。这里只回答三件事：关系还在不在
/// （`adopt` / `sever` / `isPaired`）、这一次请求带什么票（`ticket` / `validAccessToken`）、
/// 撞上 401 之后怎么办（`perform`）。
///
/// **发字节那半不在这里**，在 `HttpTransport` —— 它不认识票，于是「换票那一发不带票」
/// 不是一条纪律，而是结构上拿不到票源：票闸在 `perform`，裸发层没有它。
/// 401 的两种读法（「换票再来」与「关系断了」）仍只在本类判：裸发层只负责把
/// 「这是一次鉴权请求」这个**事实**传上来（`treat401AsRefusal`），怎么处置由这里决定。
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
@Observable
final class RpcClient {

    /// 地址与传输的主人。本类只读它，不存副本 —— 两条链路读同一个实例，
    /// 否则「组网激活换了这一份、那一份没换」会表现为「切了隧道仍往老地址打」。
    private let endpoint: Endpoint
    /// 裸发层 —— 票闸在下面，它不认识票。
    private let http: HttpTransport

    /// 设备凭证在手机侧的家。默认共享单例：全 App 一个身份。
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
    /// **为什么不参与观察（`@ObservationIgnored`）**：它是 `lazy`，而 `@Observable`
    /// 把存储属性改写成计算属性，`lazy` 在计算属性上不成立。它也不需要被观察 ——
    /// 票的生命周期变化只经 `isPaired` 与 `perform` 的结果体现，没有读者看它本身。
    @ObservationIgnored
    private lazy var tickets = TicketKeeper { [weak self] deviceToken in
        guard let self else { return .retryLater }
        return await self.renewTicket(deviceToken: deviceToken)
    }

    /// 关系是否存在（设备凭证在沙盒里）。配对成功置真，被撤销置假。
    private(set) var isPaired: Bool

    /// 协议里的唯一端点 —— 所有 op 都打这一个地址，靠信封里的 `op` 分派。
    /// 多端点会把资源语义烧进 URL：客户端就得记住哪个资源走哪个地址，
    /// 而这件事协议已经从请求体里回答过了。
    nonisolated static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

    init(endpoint: Endpoint, credentials: CredentialStore? = nil) {
        // nil 默认值是为了避开跨 actor 的默认表达式求值。
        let store = credentials ?? .shared
        self.endpoint = endpoint
        self.http = HttpTransport(endpoint: endpoint)
        self.credentials = store
        self.isPaired = store.hasDeviceToken
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
    /// - Parameter authenticated: 这次请求要不要票。**配对是唯一的 `false`** ——
    ///   换票自己不走这条路（它直接经 `HttpTransport.send`，结构上拿不到票）。
    ///   401 该怎么读也由它定（见 `HttpTransport.send`）—— 两件事同源，所以只收一个参数。
    func perform<Request: Encodable, Response: GatewayResponse>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        // 未激活 = 没有地址可打：fail-fast，不猜地址。
        guard let baseURL = endpoint.baseURL else { throw RpcClientError.notActivated }
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

