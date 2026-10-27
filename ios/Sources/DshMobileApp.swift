import SwiftUI

/// dsh-mobile 的 iPhone 客户端：会话列表 / 会话详情 / 配对 / 审批四个界面的根部，
/// 也是协议纯度的一面镜子 —— 客户端若需要改协议才跑得起来，说明协议没设计对。
///
/// 根部三段，各只有一件事：
/// - **造**：App 级对象与首屏 state 全在这里构造，别处不出现 `Xxx(`。
/// - **接**：长连接只拿四个能力、不拿一元客户端本体；两张表（待答、列表）都在这里接上
///   事件流 —— 都是 App 级事件，与该不该显示哪一屏无关。
/// - **选屏**：`RootScreen` 里那个 `switch` 是全应用唯一一处「显示哪一屏」。任何一屏内部
///   不再自己让位。
///
/// 它只比较「阶段」这种有限枚举，不运算领域值 —— 领域规则一律在状态层。
@main
struct DshMobileApp: App {
    @State private var node: TailnetNode
    @State private var store: MeshStore
    /// 到网关的常驻连接 —— App 级、唯一实例。会话详情只在它上面开关流。
    @State private var link: LongConnection
    /// 一元客户端。根部要读 `isPaired` 才决定显示哪一屏，所以它是可观察的 `@State`
    /// 而不是 `let` —— 与 `node` / `store` / `link` 同一行列。
    @State private var client: RpcClient
    /// 地址与传输的主人 —— 两条链路读同一个实例，装配根只造一次。
    private let endpoint: Endpoint
    /// 连接级事件流的收端 —— App 级，与连接同寿。三个消费方：待答表（清空）、
    /// 会话列表（逐个事件 + 代次重拉）、列表的事件订阅接线。
    private let events: EventStream
    /// 待答审批 —— App 级、唯一实例。不随任何一屏生死：停在会话列表时它照样在收。
    @State private var approvals: ApprovalStore
    /// 列表屏的 state。单实例、构造只要 client ⇒ 按「上一级造」归根部。
    /// 它的寿命因此是进程级：离开详情再回来，列表照旧在原地（它本来就是栈根）。
    @State private var listState: SessionListState
    /// 配对屏的 state。单实例、无运行期参数 ⇒ 同样归根部。
    /// 三条展示路径共用它（未配对时的整屏、列表的组网设置、详情的组网设置）。
    @State private var pairing: PairingState
    /// 组网录入那一段的 state —— 同一屏的第二个部件（换路径，与换身份分开）。
    /// 它也在这里造，于是「读一次盘」发生在启动时，而不是每次视图重建。
    @State private var meshSetup: MeshSetupState
    /// 造会话详情容器的能力。它要 `sessionId`（点开那一行才知道），根造不了那一个，
    /// 但知道 `client` / `link` —— 于是把「造」交出去，把「用什么造」留在这里。
    private let makeDetail: (SessionSummary) -> SessionDetailState

    init() {
        let node = TailnetNode()
        let endpoint = Endpoint()
        let client = RpcClient(endpoint: endpoint)
        let store = MeshStore(endpoint: endpoint, node: node)
        // 长连接只拿四个能力，不拿一元客户端本体：票 / 换票 / 传输 / 地址都在这里接一次，
        // 之后它再也不认识 `RpcClient`。四个参数必填 —— 漏接一个编译不过。
        let link = LongConnection(
            authorization: { [weak client] in client?.validAccessToken() },
            renewTicket: { [weak client] in
                guard let client else { return .unavailable }
                return await client.ticket()
            },
            // 两条链路读同一个端点实例：组网激活换的就是它，不存在第二份副本。
            session: { [weak endpoint] in endpoint?.session ?? .shared },
            baseURL: { [weak endpoint] in endpoint?.baseURL }
        )
        let events = EventStream()
        let approvals = ApprovalStore(answerer: GatewayApprovalAnswerer(client: client))
        let pairing = PairingState(client: client)
        // 组网段的两个动作都以闭包交给它：它不认识 `MeshStore`，只认识「提交一份」与
        // 「按存下来的那份重试」。
        let meshSetup = MeshSetupState(
            submit: { [weak store] key, config in await store?.submitMeshKey(key, config: config) },
            retry: { [weak store] config in await store?.retryMesh(config: config) }
        )
        // 地址读的是通信域的只读投影：本层认识 `Endpoint`，列表那一层只收到一个返回串的能力。
        let listState = SessionListState(
            client: client,
            address: { [weak endpoint] in gatewayAddressLine(endpoint?.baseURL) }
        )

        self.endpoint = endpoint
        self.events = events
        self.makeDetail = { session in
            SessionDetailState(client: client, session: session, link: link)
        }
        _node = State(initialValue: node)
        _store = State(initialValue: store)
        _client = State(initialValue: client)
        _link = State(initialValue: link)
        _approvals = State(initialValue: approvals)
        _pairing = State(initialValue: pairing)
        _meshSetup = State(initialValue: meshSetup)
        _listState = State(initialValue: listState)
    }

    var body: some Scene {
        WindowGroup {
            RootScreen(
                client: client,
                listState: listState,
                makeDetail: makeDetail,
                // 已配对那一支出现时接上长连接。连接必须有身份才有意义（无票可换时
                // 传输层把它当终态，不会自己再试），而「刚配上」正是那一支第一次出现。
                onConnectionStart: {
                    // 两行都要：`activate` 是「第一次要一条连接」，它的闸只让第一次通过；
                    // `reconnectNow` 覆盖另一条路径 —— 关系被撤销后重新配上时 `active`
                    // 已是真，`activate` 会被挡掉，连接停在 idle 不动。
                    link.activate()
                    link.reconnectNow()
                    events.attach(to: link)
                },
                // 回前台：探活 + 立即重连。上游「恢复立即试」的复现；已就绪 / 握手中的
                // 连接不受影响，不会叠加。
                onSceneActive: {
                    Task { await store.sceneActive() }
                    link.reconnectNow()
                    // 被终态拒绝收起的那条流只在这一刻重建：重试同一个拒绝没有意义。
                    // 它幂等 —— 正常情况 `attach` 的闸会直接放行。
                    events.attach(to: link)
                },
                // 组网就绪即重连（与列表「就绪即首载」对称）：connecting 期间连接
                // 在退避循环里空转（端点不存在），就绪此刻不必再等下一轮退避。
                onMeshReady: {
                    link.reconnectNow()
                }
            )
            // 启动编排挂在这里，不挂在某一屏上：未配对时列表根本不存在，而组网段
            // （配对屏里那一段）此刻就要能用。`switch` 换分支不改这个视图的身份，
            // 所以编排只跑一次。
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
            // 两张表的事件订阅是 App 级接线，与「显示哪一屏」无关，所以不等配对：
            // 待答表停在列表页时也在收，列表要能看见别的设备上发生了什么。
            .task {
                approvals.attach(events: events)
                listState.attach(events: events)
            }
            // 注在根部：推入的视图与三处 sheet 都继承这里的环境（`ApprovalStore` 只在
            // 这里注入，而详情正文读得到 —— 这就是「继承成立」的现成证据）。
            .environment(store)
            .environment(approvals)
            .environment(pairing)
            .environment(meshSetup)
        }
    }
}

/// 组合根的视图半边：**全应用唯一一处选屏**，加三条 App 级事件的重连点。
///
/// 它在这里而不在 `App.body` 里，理由是可判的：Observation 的追踪只对 **View 的 body**
/// 有文档保证（`App.body` 返回的是 `Scene`）。选屏读 `isPaired`、重连点读 `store.phase`，
/// 两处都靠追踪才会重新求值 —— 放在 Scene 里是「大概行」，放在 View 里是「一定行」。
///
/// 它认识服务（`client` 与三个闭包），因为它是装配点的视图面，不是某一屏的渲染段：
/// 渲染段的规矩（字段里没有服务）从这里往下才开始算。
private struct RootScreen: View {
    let client: RpcClient
    let listState: SessionListState
    let makeDetail: (SessionSummary) -> SessionDetailState
    /// 已配对那一支出现：接上长连接（`activate` + 事件流登记）。
    let onConnectionStart: () -> Void
    /// 回前台：探活 + 重连。
    let onSceneActive: () -> Void
    /// 组网就绪：立刻重连，不等下一轮退避。
    let onMeshReady: () -> Void

    /// 组网阶段 —— 重连点读它。
    @Environment(MeshStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            switch stage {
            case .needsPairing:
                PairingView()
            case .ready:
                SessionListView(state: listState, makeDetail: makeDetail)
                    .task { onConnectionStart() }
                    // 这一支出现 ⟺ 身份刚成立（或启动时已成立）。连接在这里接，不在启动
                    // 编排里：未配对时它没有票可换，传输层把「无票」当终态收起，之后
                    // 再没有人会把它拉起来。
            }
        }
        .onChange(of: store.phase) { _, phase in
            guard case .ready = phase else { return }
            onMeshReady()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            onSceneActive()
        }
    }

    /// 应用此刻处于哪个阶段。只有两个取值、一个条件 —— 提成独立值类型只是把一行 `if`
    /// 变成两处样板；出现第三个取值（比如启动中）时再提，那时它有资格占一个类型。
    private var stage: Stage {
        client.isPaired ? .ready : .needsPairing
    }

    private enum Stage {
        /// 还没有设备凭证：整屏交给配对。
        case needsPairing
        /// 有凭证：主界面。
        case ready
    }
}
