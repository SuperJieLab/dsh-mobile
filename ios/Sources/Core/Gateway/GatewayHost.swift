import Combine
import Foundation

/**
 * 到网关的那一条**常驻连接** —— App 级，唯一实例，由根部创建。
 *
 * 它只装一件事：连接的生命周期归谁。归 App —— 前台期间要一条传输，会话详情只在这条
 * 传输上**造一条流**。屏幕那一侧永远看不到「进屏重新握手、离屏丢掉整窗」这件事。
 *
 * 为什么需要这一层而不是在根部直接拿 `GatewayConnection`：阶段要能被 SwiftUI 观察
 *（功能条的网络格），而传输层不碰 Combine 的发布机制。这一层只搬运阶段与转发造流，
 * 不判断任何东西 —— 判据仍在传输层与流表，屏幕上的事仍在状态层。
 *
 * **连接参数只在这里绑一次**：票在哪取、传输换成哪一条、地址从哪来，三件都是「怎么连」
 * 的一半，与「看哪个会话」无关。订阅方因此拿不到它们，也就不可能长出第二个决策者。
 *
 * 屏幕那一侧拿到的不是这个类型，而是 `StreamFactory` —— 它没有连接级动作。
 */
@MainActor
final class GatewayHost: ObservableObject, StreamFactory {

    /// 连接阶段 —— 功能条网络格与连接详情的数据源。
    @Published private(set) var phase: ConnectionPhase = .idle

    private let transport: GatewayConnection

    init(client: RpcClient) {
        let transport = GatewayConnection()
        self.transport = transport

        transport.onPhaseChange = { [weak self] phase in self?.phase = phase }
        // upgrade 时刻取一张有效的 access —— 经 client 取而不是 `CredentialStore.shared`：
        // HTTP 那条也走 client 注入的 store，两条路径必须同源，否则换掉注入实例之后它们
        // 会各自为政。
        transport.authorizationProvider = { [weak client] in client?.validAccessToken() }
        // 换票只是「给一个能力」：换到之后该重连、换不到该等还是该停，由传输层自己按结果
        // 决定（见 `renewThenRetry`）—— 那是连接编排，不是这一层的事。
        transport.ticketRenewer = { [weak client] in
            guard let client else { return .unavailable }
            return await client.ticket()
        }
        // 传输与地址每次建连现取 —— 组网激活（client.activate）后下一轮连接即走 tailnet。
        transport.sessionProvider = { [weak client] in client?.meshSession ?? .shared }
        transport.baseURLProvider = { [weak client] in client?.baseURL }
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
        transport.mux.makeStream(behavior)
    }
}
