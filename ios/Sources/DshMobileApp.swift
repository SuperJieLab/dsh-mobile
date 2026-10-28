import SwiftUI

/// dsh-mobile 的 iPhone 客户端根部：五个界面的装配点，也是协议纯度的一面镜子 —— 客户端
/// 若需要改协议才跑得起来，说明协议没设计对。
///
/// 根部三段，各只有一件事：
/// - **造**：App 级对象与常驻 state 全在这里构造，别处不出现 `Xxx(`。
/// - **接**：长连接只拿四个能力、不拿一元客户端本体；两张表（待答、列表）都在这里接上
///   事件流 —— 都是 App 级事件，与显示哪一屏无关。
/// - **装配目的地**：`RootScreen` 里那张 `navigationDestination` 是全应用唯一一处把
///   `Destination` 换成屏的地方。屏只发值，下一屏要什么在这里给。
@main
struct DshMobileApp: App {
    @State private var node: TailnetNode
    @State private var store: MeshStore
    /// 到网关的常驻连接。会话详情只在它上面开关流。
    @State private var link: LongConnection
    /// 请求门面（带票发一次）。不可观察 —— 身份的真值在 `credentials` 那里。
    @State private var client: RpcClient
    /// 身份的真值。设置页、配对页、`RpcClient` 换票都读它 —— 一个实例、没有副本。
    private let credentials: CredentialStore
    /// 连接级事件流的收端 —— App 级，与连接同寿。三个消费方：待答表、会话列表、
    /// 列表的订阅接线。
    private let events: EventStream
    /// 待答审批。不随任何一屏生死：停在会话列表时它照样在收。
    @State private var approvals: ApprovalStore
    /// 列表的 state。进程级：它是栈根，离开详情再回来照旧在原地。
    @State private var listState: SessionListState
    /// 造配对页容器的工厂。**草稿不跨进出存活**：6 位码 10 分钟失效，留着上次那半截码
    /// 是陷阱 —— 所以不是单例，是「进屏造一个」。
    private let makePairing: () -> PairingState
    /// 组网录入（换路径那一半）。在这里造，于是「读一次盘」发生在启动时。
    @State private var meshSetup: MeshSetupState
    /// 设置页的依赖面。
    @State private var settings: SettingsState
    /// 造会话详情容器的能力。它要 `sessionId`（点开那一行才知道），根造不了那一个，
    /// 但知道 `client` / `link` —— 于是把「造」交出去，把「用什么造」留在这里。
    private let makeDetail: (SessionSummary) -> SessionDetailState

    init() {
        let node = TailnetNode()
        // 组网域先造：隧道的产物（传输 + 地址）只住在它那里，两条链路向它取。
        let store = MeshStore(node: node)
        // 身份的真值：一个实例，两处读 —— `RpcClient` 换票时取凭证，各处闭包读
        // 「有没有」。「已配对 ≡ 有凭证」因此是结构，不是纪律。
        let credentials = CredentialStore.shared
        let client = RpcClient(
            session: { [weak store] in store?.route?.session ?? .shared },
            baseURL: { [weak store] in store?.route?.baseURL },
            credentials: credentials
        )
        // 长连接只拿四个能力，不拿一元客户端本体：票 / 换票 / 传输 / 地址都在这里接一次，
        // 之后它再也不认识 `RpcClient`。四个参数必填 —— 漏接一个编译不过。
        let link = LongConnection(
            authorization: { [weak client] in client?.tickets.validToken() },
            renewTicket: { [weak client] in
                guard let client else { return .unavailable }
                return await client.ticket()
            },
            // 两条链路读同一份产物：组网激活换的就是它，不存在第二份副本。
            session: { [weak store] in store?.route?.session ?? .shared },
            baseURL: { [weak store] in store?.route?.baseURL }
        )
        let events = EventStream()
        let approvals = ApprovalStore(answerer: GatewayApprovalAnswerer(client: client))
        // 配对段的三件事都以闭包交出去：它不认识 `RpcClient`，也不认识凭证存在哪。
        let makePairing: () -> PairingState = {
            PairingState(
                submit: { [weak client] code in
                    guard let client else { throw RpcClientError.notActivated }
                    try await pairDevice(client, code: code, into: credentials)
                },
                hasIdentity: { [weak credentials] in credentials?.hasDeviceToken ?? false },
                discardIdentity: { [weak client] in
                    client?.discardIdentity(reason: .userRequested)
                }
            )
        }
        // 组网段的两个动作都以闭包交给它：它不认识 `MeshStore`，只认识「提交一份」与
        // 「按存下来的那份重试」。
        let meshSetup = MeshSetupState(
            submit: { [weak store] key, config in await store?.submitMeshKey(key, config: config) },
            retry: { [weak store] config in await store?.retryMesh(config: config) }
        )
        let settings = SettingsState(
            setup: meshSetup,
            store: store,
            hasIdentity: { [weak credentials] in credentials?.hasDeviceToken ?? false },
            discardIdentity: { [weak client] in
                client?.discardIdentity(reason: .userRequested)
            }
        )
        let listState = SessionListState(client: client)

        self.credentials = credentials
        self.makePairing = makePairing
        self.events = events
        self.makeDetail = { session in
            SessionDetailState(client: client,
                               session: session,
                               link: link,
                               store: store,
                               approvals: approvals)
        }
        _node = State(initialValue: node)
        _store = State(initialValue: store)
        _client = State(initialValue: client)
        _link = State(initialValue: link)
        _approvals = State(initialValue: approvals)
        _meshSetup = State(initialValue: meshSetup)
        _settings = State(initialValue: settings)
        _listState = State(initialValue: listState)
    }

    var body: some Scene {
        WindowGroup {
            RootScreen(
                identity: credentials,
                list: listState,
                store: store,
                meshSetup: meshSetup,
                settings: settings,
                makeDetail: makeDetail,
                makePairing: makePairing,
                // 三条 App 级事件的执行体在根上（见 `RootScreen`）：它们只碰这两个能力，
                // 于是收成字段而不是闭包 —— 闭包会把「何时发生」与「做什么」拆到两处。
                link: link,
                events: events
            )
            // 启动编排挂在这里，不挂在某一屏上：组网要在用户还没进任何一屏时就跑起来，
            // 而根的身份是稳定的，所以编排只跑一次。
            //
            // 启动编排（兜底激活 → 组网 → 激活内化）全在 store.start。
            // 配置读坏了不交给节点：空配置只会换来一个误导的「不可达」。
            .task {
                if case .damaged = MeshConfig.read() {
                    store.reportDamagedConfiguration()
                } else {
                    await store.start(config: MeshConfig.load())
                }
            }
            // 两张表的事件订阅是 App 级接线，不等身份成立：待答表停在列表页时也在收，
            // 列表要能看见别的设备上发生了什么。
            .task {
                approvals.attach(events: events)
                listState.attach(events: events)
            }
        }
    }
}

/// 组合根的视图半边：**全应用唯一一处目的地装配**，加三条 App 级事件的执行体。
///
/// 它在这里而不在 `App.body` 里，理由是可判的：Observation 的追踪只对 **View 的 body**
/// 有文档保证（`App.body` 返回的是 `Scene`）。身份与 `store.phase` 都靠追踪才会重新求值
/// —— 放在 Scene 里是「大概行」，放在 View 里是「一定行」。同理 `.task` 只长在 `View` 上，
/// `Scene` 没有这个修饰符，而启动编排与两张表的接线都靠它。
///
/// **它认识全部服务，因为它是装配点**：四个目的地的依赖都在这里接上，屏只发 `Destination`
/// 值。于是下一屏要什么不必穿透中间层。
private struct RootScreen: View {
    /// 身份的真值。它可观察 —— 凭证一变这一屏就重算。
    let identity: CredentialStore
    let list: SessionListState
    /// 连接域 —— 组网配置页读节点五态，重连点读 `phase`。
    let store: MeshStore
    let meshSetup: MeshSetupState
    let settings: SettingsState
    let makeDetail: (SessionSummary) -> SessionDetailState
    /// 配对页的容器由它造（凭证在哪只有这一层知道）。
    let makePairing: () -> PairingState
    /// 长连接。三条 App 级事件里有两条半要它 —— 收成字段而不是闭包。
    let link: LongConnection
    /// 连接级事件流的收端。身份成立与回前台各接一次。
    let events: EventStream

    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            // 列表永远是根。前置条件不满足时它只在顶部提示（那条提示由列表自己画）——
            // 正在读会话的人不会被整屏弹走，而修配置从齿轮开始。
            //
            // 页脚那句地址在这里现算：列表只收「读一句字」的能力，而它不该为此认识 `MeshStore`。
            SessionListView(list: list, store: store,
                            address: { gatewayAddressLine(store.route?.baseURL) })
                .navigationDestination(for: Destination.self) { route in
                    switch route {
                    case .session(let session):
                        SessionDetailView(session: session, make: makeDetail)
                    case .settings:
                        SettingsView(state: settings)
                    case .mesh:
                        MeshSettingsView(setup: meshSetup, store: store)
                    case .pairing:
                        PairingScreen(make: makePairing)
                    }
                }
                // 连接在这里接：它必须有身份才有意义（无票可换时传输层把「无票」当终态
                // 收起，不会自己再试），而「身份刚成立」正是这一刻。用 `.task(id:)` 钉住
                // 身份 —— 写成无 id 的 `.task` 只在首帧跑一次，重新配对之后不会再来一次。
                .task(id: identity.hasDeviceToken) {
                    guard identity.hasDeviceToken else { return }
                    // 两行都要：`activate` 是「第一次要一条连接」，它的闸只让第一次通过；
                    // `reconnectNow` 覆盖另一条路径 —— 关系被撤销后重新配上时 `active`
                    // 已是真，`activate` 会被挡掉，连接停在 idle 不动。
                    link.activate()
                    link.reconnectNow()
                    events.attach(to: link)
                }
        }
        // 组网就绪即重连（与列表「就绪即首载」对称）：connecting 期间连接在退避循环里
        // 空转（端点不存在），就绪此刻不必再等下一轮退避。
        .onChange(of: store.phase) { _, phase in
            guard case .ready = phase else { return }
            link.reconnectNow()
        }
        // 回前台：探活 + 立即重连。上游「恢复立即试」的复现；已就绪 / 握手中的连接
        // 不受影响，不会叠加。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.sceneActive() }
            link.reconnectNow()
            // 被终态拒绝收起的那条流只在这一刻重建：重试同一个拒绝没有意义。
            // 它幂等 —— 正常情况 `attach` 的闸会直接放行。
            events.attach(to: link)
        }
    }
}
