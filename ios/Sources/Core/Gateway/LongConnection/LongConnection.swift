import Foundation

/**
 * 到网关的那一条**常驻连接** —— App 级，唯一实例，由根部创建。连接的生命周期归 App：
 * 前台期间要一条传输，会话详情只在这条传输上开关流。
 * 这一层只做三件事：持有两者、接上三个接点、转发阶段与造流；它不判断任何东西。
 * **连接参数只在这里绑一次**（票在哪取、传输是哪条、地址从哪来）：订阅方拿不到它们。
 */
@MainActor
@Observable
final class LongConnection: StreamFactory {

    /// 连接阶段 —— 功能条网络格与连接详情的数据源。
    private(set) var phase: ConnectionPhase = .idle

    private let transport: WebSocketConnection
    private let streams: StreamMux

    /// 四个能力都由根部注入，**全部必填**（其中两个来自端点层）。
    /// 收闭包而不收一元客户端：要的只是「一张票 / 一次换票 / 一条传输 / 一个地址」四件事，
    /// 收类型就等于把整台客户端抱进来。收闭包之后本类源码里一个 `RpcClient` 都没有，而
    /// 「忘了注入」也编译不过。
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
        // 漏 onFrame 则界面永远空，漏 onPhaseChanged 则网络格不动。
        streams.attach(channel: transport)
        transport.onFrame = { [weak streams] envelope, raw in
            streams?.receive(envelope, raw: raw)
        }

        transport.onPhaseChanged = { [weak self] _, new in self?.phase = new }
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

    /// 立刻要一条连接（跳过退避）。**连接级动作** —— 只给根部与组网就绪那条触发用，
    /// 屏幕手里没有这个成员。
    /// - Parameter reason: 谁在要。日志据此分辨触发点 —— 几处触发共用一个动作。
    func reconnectNow(reason: String) {
        transport.reconnectNow(reason: reason)
    }

    /// 换一条连接：隧道产物换代了，旧 socket 连的是上一代的会话，留着它只会往那边发。
    ///
    /// **不用 `deactivate()` + `activate()`**：`deactivate` 是 App 收尾用的生命周期动作，它经
    /// `onStopped` 把流表整个清空，逻辑流再也回不来（`reopenAll` 只认代次变化，不认重新激活）。
    /// 换一条只要重跑一次 `connect()`：关旧 socket、代次 +1、按此刻的地址重建、通知流层换号重开。
    /// 未激活时它是空操作（`connect` 自己守 `active`）—— 换代不该把后台的 App 叫起来连网。
    /// - Parameter reason: 谁在要。与 `reconnectNow` 同样留原因，排障时才分得清哪次重连为哪件事。
    func replaceConnection(reason: String) {
        Log.info(Log.Module.session, "replace connection (\(reason)) — tunnel product replaced")
        transport.connect()
    }

    /// 造一条流。屏幕与 App 级订阅方各调一次 —— 两者平级，谁都不占谁的位。
    @discardableResult
    func makeStream(_ behavior: any StreamBehavior) -> LogicalStream? {
        streams.makeStream(behavior)
    }
}
