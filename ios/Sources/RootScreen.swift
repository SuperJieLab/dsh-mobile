import SwiftUI

/// 组合根的视图半边：**全应用唯一一处目的地装配**，加三条 App 级事件的执行体。
///
/// 它在这里而不在 `App.body` 里，理由是可判的：Observation 的追踪只对 **View 的 body**
/// 有文档保证（`App.body` 返回的是 `Scene`）。身份与 `store.phase` 都靠追踪才会重新求值
/// —— 放在 Scene 里是「大概行」，放在 View 里是「一定行」。同理 `.task` 只长在 `View` 上，
/// `Scene` 没有这个修饰符，而启动编排与待答表的接线都靠它。
///
/// **它不造任何屏级状态**：四个目的地各自造自己的（`SessionListAssembler` 等）。
/// 这里只把服务传下去 —— 屏只发 `Destination` 值，下一屏要什么在这一处接上。
struct RootScreen: View {
    /// 全部基础服务。与进程同寿 —— 它是这个视图唯一的一处依赖来源。
    private let services: AppServices

    @Environment(\.scenePhase) private var scenePhase

    /// 显式 `init`：属性全 `private` 时 memberwise 那一份也是 `private`，`App` 就造不出来。
    init(services: AppServices) {
        self.services = services
    }

    /// 三个装配段要的闭包。**先取局部量再接闭包**：`[weak x]` 那一格只接受一个标识符，
    /// 而 `services` 是属性 —— 拿属性的值得先落成局部量。
    private var hasIdentity: () -> Bool {
        let credentials = services.credentials
        return { credentials.hasDeviceToken }
    }

    private var discardIdentity: () -> Void {
        let client = services.client
        return { client.discardIdentity(reason: .userRequested) }
    }

    private var submitPairingCode: (String) async throws -> Void {
        let client = services.client
        let credentials = services.credentials
        return { code in try await pairDevice(client, code: code, into: credentials) }
    }

    var body: some View {
        NavigationStack {
            // 列表永远是根。前置条件不满足时它只在顶部提示（那条提示由列表自己画）——
            // 正在读会话的人不会被整屏弹走，而修配置从齿轮开始。
            SessionListAssembler(client: services.client,
                                 events: services.events,
                                 store: services.store)
                .navigationDestination(for: Destination.self) { route in
                    switch route {
                    case .session(let session):
                        SessionDetailAssembler(session: session,
                                               client: services.client,
                                               link: services.link,
                                               store: services.store,
                                               approvals: services.approvals)
                    case .settings:
                        SettingsAssembler(store: services.store,
                                          hasIdentity: hasIdentity,
                                          discardIdentity: discardIdentity)
                    case .mesh:
                        MeshSettingsAssembler(store: services.store)
                    case .pairing:
                        PairingAssembler(submit: submitPairingCode,
                                         hasIdentity: hasIdentity,
                                         discardIdentity: discardIdentity)
                    }
                }
                // 连接在这里接：它必须有身份才有意义（无票可换时传输层把「无票」当终态
                // 收起，不会自己再试），而「身份刚成立」正是这一刻。用 `.task(id:)` 钉住
                // 身份 —— 写成无 id 的 `.task` 只在首帧跑一次，重新配对之后不会再来一次。
                .task(id: services.credentials.hasDeviceToken) {
                    guard services.credentials.hasDeviceToken else { return }
                    // 两行都要：`activate` 是「第一次要一条连接」，它的闸只让第一次通过；
                    // `reconnectNow` 覆盖另一条路径 —— 关系被撤销后重新配上时 `active`
                    // 已是真，`activate` 会被挡掉，连接停在 idle 不动。
                    services.link.activate()
                    services.link.reconnectNow()
                    services.events.attach(to: services.link)
                }
        }
        // 组网就绪即重连（与列表「就绪即首载」对称）：connecting 期间连接在退避循环里
        // 空转（端点不存在），就绪此刻不必再等下一轮退避。
        .onChange(of: services.store.phase) { _, phase in
            guard case .ready = phase else { return }
            services.link.reconnectNow()
        }
        // 回前台：探活 + 立即重连。上游「恢复立即试」的复现；已就绪 / 握手中的连接
        // 不受影响，不会叠加。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await services.store.sceneActive() }
            services.link.reconnectNow()
            // 被终态拒绝收起的那条流只在这一刻重建：重试同一个拒绝没有意义。
            // 它幂等 —— 正常情况 `attach` 的闸会直接放行。
            services.events.attach(to: services.link)
        }
        // 启动编排：读盘一次，三态各走各的。配置读坏了不交给节点 —— 空配置只会换来一个
        // 误导的「不可达」。草稿那一份由组网页自己读（它才是用那份草稿的人）。
        .task {
            switch MeshConfig.read() {
            case .damaged:
                services.store.reportDamagedConfiguration()
            case .missing:
                await services.store.start(config: .unconfigured)
            case .ok(let config):
                await services.store.start(config: config)
            }
        }
        // 待答表的事件订阅是 App 级接线，不等身份成立：停在列表页时它也在收。
        // 列表的订阅不在这里 —— 它随列表屏自己的状态走（造那个 state 的人接线）。
        .task {
            services.approvals.attach(events: services.events)
        }
    }
}
