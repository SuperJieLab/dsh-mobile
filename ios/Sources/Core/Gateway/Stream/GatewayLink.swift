import Combine
import Foundation

/**
 * 到网关的那一条**常驻连接** —— App 级，唯一实例，由根部创建。
 *
 * 它只装一件事：连接的生命周期归谁。归 App —— 前台期间要一条连接，会话详情只在这条连接上
 * **登记 / 注销一条流**。屏幕那一侧永远看不到「进屏重新握手、离屏丢掉整窗」这件事。
 *
 * 为什么需要这一层而不是在根部直接拿 `FollowClient`：连接阶段要能被 SwiftUI 观察
 * （功能条的网络格），而连接层不碰 Combine 的发布机制。这一层只搬运阶段与转发登记，
 * 不判断任何东西 —— 判据仍在连接层，屏幕上的事仍在状态层。
 *
 * **连接参数只在这里绑一次**：票在哪取、传输换成哪一条、地址从哪来，三件都是「怎么连」
 * 的一半，与「看哪个会话」无关。订阅方因此拿不到它们，也就不可能长出第二个决策者。
 *
 * 屏幕那一侧拿到的不是这个类型，而是 `SessionStreamHandle` —— 它没有连接级动作。
 */
@MainActor
final class GatewayLink: ObservableObject, SessionStreamHandle, ConnectionStreamOpening,
                         UnscopedFrameFeed {

    /// 连接阶段 —— 功能条网络格与连接详情的数据源。
    @Published private(set) var phase: FollowClient.Phase = .idle

    private let follow: FollowClient

    /// - Parameter follow: 默认自己造一个（`nil` 而不是默认表达式：跨 actor 的默认值
    ///   求值不合法）。可注入是为了**这一跳能被断言** —— 转发成员写成空实现时，
    ///   两端各自的判据都还是绿的。
    init(client: GatewayClient, follow: FollowClient? = nil) {
        let follow = follow ?? FollowClient()
        self.follow = follow

        follow.onPhaseChange = { [weak self] phase in self?.phase = phase }
        // upgrade 时刻取一张有效的 access —— 经 client 取而不是 `CredentialStore.shared`：
        // HTTP 那条也走 client 注入的 store，两条路径必须同源，否则换掉注入实例之后它们
        // 会各自为政。
        follow.authorizationProvider = { [weak client] in client?.validAccessToken() }
        // 换票只是「给一个能力」：换到之后该重连、换不到该等还是该停，由 `FollowClient`
        // 自己按结果决定（见 `renewThenRetry`）—— 那是连接编排，不是这一层的事。
        follow.ticketRenewer = { [weak client] in
            guard let client else { return .unavailable }
            return await client.ticket()
        }
        // 传输与地址每次建连现取 —— 组网激活（client.activate）后下一轮连接即走 tailnet。
        follow.sessionProvider = { [weak client] in client?.meshSession ?? .shared }
        follow.baseURLProvider = { [weak client] in client?.baseURL }
    }

    /// 要一条连接（App 到前台）。此刻可以一条流都没有 —— 停在会话列表也连着。
    func activate() {
        follow.activate()
    }

    /// 不要连接了（App 收尾）。
    func deactivate() {
        follow.deactivate()
    }

    /// 会话详情进屏：登记一份订阅。
    func open(_ subscription: FollowClient.Subscription) {
        follow.open(subscription)
    }

    /// 会话详情离屏：注销自己那一次登记。晚到的注销不碰后来者。
    func close(owner: AnyObject) {
        follow.close(owner: owner)
    }

    /// 这一条流的基线丢了（未定稿断号、服务端正常收尾）：换一个编号在本连接上重开。
    /// 连接与别的流不动。
    func reopen(owner: AnyObject) {
        follow.reopen(owner: owner)
    }

    /// 回前台 / 组网就绪：立即重连（跳过退避）。**连接级动作** —— 只给根部用，
    /// 屏幕手里没有这个成员。
    func reconnectNow() {
        follow.reconnectNow()
    }

    // MARK: - 无编号帧

    /// 无编号帧的收货人 —— App 级，与连接同寿。
    var unscopedSink: (any UnscopedFrameSink)? {
        get { follow.unscopedSink }
        set { follow.unscopedSink = newValue }
    }
}
