import SwiftUI

/// 组合根的视图半边：**全应用唯一一处目的地装配**，加三条 App 级事件的执行体。
///
/// 它在这里而不在 `App.body` 里，理由是可判的：Observation 的追踪只对 **View 的 body**
/// 有文档保证（`App.body` 返回的是 `Scene`）。身份与 `store.phase` 都靠追踪才会重新求值
/// —— 放在 Scene 里是「大概行」，放在 View 里是「一定行」。同理 `.task` 只长在 `View` 上，
/// `Scene` 没有这个修饰符，而启动编排与两张表的接线都靠它。
///
/// **它认识全部服务，因为它是装配点**：四个目的地的依赖都在这里接上，屏只发 `Destination`
/// 值。于是下一屏要什么不必穿透中间层。
struct RootScreen: View {
    /// 全部基础服务。与进程同寿 —— 它是这个视图唯一的一处依赖来源。
    private let services: AppServices

    /// 三个会变的屏级状态。它们各自该归哪一屏是下一步的事；住在这里的唯一理由是
    /// 「造它们要服务，而服务在这一层」。
    ///
    /// `@State` 只采用第一个值，所以下面 `init` 里那几次构造会有多余的 —— 这是允许的，
    /// 前提是构造本身没有副作用（不读盘、不启动、不发请求）。
    @State private var list: SessionListState
    @State private var meshSetup: MeshSetupState
    @State private var settings: SettingsState

    init(services: AppServices) {
        self.services = services
        let store = services.store
        let client = services.client
        let credentials = services.credentials
        _list = State(initialValue: SessionListState(client: client))
        _meshSetup = State(initialValue: MeshSetupState(
            stored: .unconfigured,
            submit: { [weak store] key, config in await store?.submitMeshKey(key, config: config) },
            retry: { [weak store] config in await store?.retryMesh(config: config) }
        ))
        _settings = State(initialValue: SettingsState(
            store: store,
            hasIdentity: { [weak credentials] in credentials?.hasDeviceToken ?? false },
            discardIdentity: { [weak client] in
                client?.discardIdentity(reason: .userRequested)
            }
        ))
    }

    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            // 列表永远是根。前置条件不满足时它只在顶部提示（那条提示由列表自己画）——
            // 正在读会话的人不会被整屏弹走，而修配置从齿轮开始。
            //
            // 页脚那句地址在这里现算：列表只收「读一句字」的能力，而它不该为此认识 `MeshStore`。
            SessionListView(list: list, store: services.store,
                            address: { gatewayAddressLine(services.store.route?.baseURL) })
                .navigationDestination(for: Destination.self) { route in
                    switch route {
                    case .session(let session):
                        // 详情容器要 `sessionId`（点开那一行才知道），所以把「造」交出去；
                        // 「用什么造」留在这里 —— 服务只有这一层有。
                        SessionDetailView(session: session) { session in
                            SessionDetailState(client: services.client,
                                               session: session,
                                               link: services.link,
                                               store: services.store,
                                               approvals: services.approvals)
                        }
                    case .settings:
                        SettingsView(state: settings)
                    case .mesh:
                        MeshSettingsView(setup: meshSetup, store: services.store)
                    case .pairing:
                        PairingScreen(make: {
                            PairingState(
                                submit: { [client = services.client] code in
                                    try await pairDevice(client, code: code,
                                                         into: services.credentials)
                                },
                                hasIdentity: { [credentials = services.credentials] in
                                    credentials.hasDeviceToken
                                },
                                discardIdentity: { [client = services.client] in
                                    client.discardIdentity(reason: .userRequested)
                                }
                            )
                        })
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
        // 启动编排与两张表的接线都是 App 级的一次性动作，与显示哪一屏无关。
        .task {
            switch MeshConfig.read() {
            case .damaged:
                services.store.reportDamagedConfiguration()
            case .missing:
                await services.store.start(config: .unconfigured)
            case .ok(let config):
                meshSetup.adoptStored(config)
                await services.store.start(config: config)
            }
        }
        .task {
            services.approvals.attach(events: services.events)
            list.attach(events: services.events)
        }
    }
}
