import Foundation

/**
 * 到网关的那一条**常驻连接** —— App 级，唯一实例，由根部创建。
 *
 * 它只装一件事：连接的生命周期归谁。归 App —— 前台期间要一条传输，会话详情只在这条
 * 传输上**造一条流**。屏幕那一侧永远看不到「进屏重新握手、离屏丢掉整窗」这件事。
 *
 * 为什么需要这一层：两个模板互不认识，总得有人把它们接起来；阶段还要能被 SwiftUI 观察
 *（功能条的网络格），而传输层不碰任何发布机制。这一层只做三件事 —— 持有两者、
 * 接上三个接点、转发阶段与造流。它不判断任何东西：判据仍在传输层与流表，屏幕上的事仍在状态层。
 *
 * **连接参数只在这里绑一次**：票在哪取、传输换成哪一条、地址从哪来，三件都是「怎么连」
 * 的一半，与「看哪个会话」无关。订阅方因此拿不到它们，也就不可能长出第二个决策者。
 *
 * 屏幕那一侧拿到的不是这个类型，而是 `StreamFactory` —— 它没有连接级动作。
 */
@MainActor
@Observable
final class LongConnection: StreamFactory {

    /// 连接阶段 —— 功能条网络格与连接详情的数据源。
    private(set) var phase: ConnectionPhase = .idle

    private let transport: WebSocketConnection
    private let streams: StreamMux

    /// 四个能力都由根部注入，**全部必填**（其中两个来自端点层）。
    ///
    /// 为什么收闭包而不是收一元客户端：这条连接要的只是「一张票 / 一次换票 / 一条传输 /
    /// 一个地址」四件事，而它们都住在一元客户端那边。收类型就等于把整台客户端抱进来 ——
    /// 那正是「为了取票认识三百行」。收闭包之后，本类源码里一个 `RpcClient` 都没有，
    /// 而「忘了注入」也编译不过（必填参数，不是可选属性）。
    init(authorization: @escaping () -> String?,
         renewTicket: @escaping () async -> AccessTicket,
         session: @escaping () -> URLSession,
         baseURL: @escaping () -> URL?) {
        let transport = WebSocketConnection()
        let streams = StreamMux()
        self.transport = transport
        self.streams = streams

        // 三个接点，这里是唯一一处：接上 Channel（事件订阅在 `attach` 内部完成）、
        // 把帧交给流表、转发阶段。漏掉任何一个的症状都不同 —— 漏 attach 则换代次不重开，
        // 漏 onFrame 则界面永远空，漏 onPhaseChange 则网络格不动。
        streams.attach(channel: transport)
        transport.onFrame = { [weak streams] envelope, raw in
            streams?.receive(envelope, raw: raw)
        }

        transport.onPhaseChange = { [weak self] phase in self?.phase = phase }
        transport.authorizationProvider = authorization
        // 换票只是「给一个能力」：换到之后该重连、换不到该等还是该停，由传输层自己按结果
        // 决定（见 `renewThenRetry`）—— 那是连接编排，不是这一层的事。
        transport.ticketRenewer = renewTicket
        // 传输与地址每次建连现取 —— 组网激活之后下一轮连接即走 tailnet。
        transport.sessionProvider = session
        transport.baseURLProvider = baseURL
    }

    /// 要一条连接（App 到前台）。此刻可以一条流都没有 —— 停在会话列表也连着。
    func activate() {
        transport.activate()
    }

    /// 回前台 / 组网就绪：立即重连（跳过退避）。**连接级动作** —— 只给根部与组网就绪那条
    /// 触发用，屏幕手里没有这个成员。
    func reconnectNow() {
        transport.reconnectNow()
    }

    /// 造一条流。屏幕与 App 级订阅方各调一次 —— 两者平级，谁都不占谁的位。
    @discardableResult
    func makeStream(_ behavior: any StreamBehavior) -> LogicalStream? {
        streams.makeStream(behavior)
    }
}
