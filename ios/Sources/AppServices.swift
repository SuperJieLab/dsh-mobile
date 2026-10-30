import Foundation

/// 这台 App 的全部基础服务：一次造好，之后只被传递、不被修改。
/// **它不是状态**：字段全是 `let`，观察不落在它身上（读 `services.store.phase` 时追踪落在
/// `MeshStore` 内部）。
/// **只造一次**来自 `App` 由运行时实例化一次；**构造顺序即依赖** —— `client` 要读 `store` 的
/// 隧道产物，`link` 要 `client` 的票。
/// 构造期唯一的 I/O 是 `credentials` 首次读设备凭证：身份是首帧就要知道的事实。
@MainActor
struct AppServices {
    /// 组网域：隧道的判据与产物都住它，两条链路向它取。它的节点对象由它自己持有。
    let store: MeshStore
    /// 身份的真值。一个实例，`RpcClient` 换票与各处闭包都读它 —— 没有第二份。
    let credentials: CredentialStore
    /// 一次请求的门面（带票发一次）。不可观察。
    let client: RpcClient
    /// 到网关的常驻连接。会话详情只在它上面开关流。
    let link: LongConnection
    /// 连接级事件流的收端，与连接同寿。两个消费方：待答表、会话列表。
    let events: EventStream
    /// 待答审批。不随任何一屏生死：停在会话列表时它照样在收。
    let approvals: ApprovalStore

    init() {
        let node = TailnetNode()
        let store = MeshStore(node: node)
        let credentials = CredentialStore.shared
        let client = RpcClient(
            session: { [weak store] in store?.route?.session ?? .shared },
            baseURL: { [weak store] in store?.route?.baseURL },
            credentials: credentials
        )
        // 长连接只拿四个能力、不拿一元客户端本体：票、换票、传输、地址都在这里接一次，
        // 之后它再也不认识 `RpcClient`。四个参数必填 —— 漏接一个编译不过。
        let link = LongConnection(
            authorization: { [weak client] in client?.tickets.validToken() },
            renewTicket: { [weak client] in
                guard let client else { return .unavailable }
                return await client.ticket()
            },
            session: { [weak store] in store?.route?.session ?? .shared },
            baseURL: { [weak store] in store?.route?.baseURL }
        )
        let events = EventStream()
        let approvals = ApprovalStore(answerer: GatewayApprovalAnswerer(client: client))

        self.store = store
        self.credentials = credentials
        self.client = client
        self.link = link
        self.events = events
        self.approvals = approvals
    }

    // MARK: - 编排

    /// 启动：**进程级一次**，由 `App.init` 开一个 Task 调。两个阶段：
    /// 1. **接线**（同步）：不能靠视图的 `.onChange` / `.task(id:)` 表达 —— 那是渲染的副作用。
    /// 2. **动作**（按 `StartupPlan` 走，组网那一步 await）。
    /// 等组网出结论：没有地址，后面几步都等不到任何数据。顺序与「等」是同一件事。
    func start() async {
        wireCrossServiceTriggers()

        let steps = StartupPlan.steps(
            hasIdentity: credentials.hasDeviceToken,
            config: MeshConfig.read()
        )
        await run(steps)
    }

    /// 回前台：按现状决定探活还是重试（组网）+ 立刻要一次连接 + 重建被终态拒绝的流。
    /// **选择住这里**，因为只有这个类型同时认识 `store.phase` 与「回到前台」；判定是
    /// `ForegroundAction.of`。
    /// `.failed(.unreachable)` 重试而不是只探活：探活对本来就不通的节点没有意义，而「用户回来了」
    func sceneActive() async {
        switch ForegroundAction.of(phase: store.phase) {
        case .revive:
            await store.revive()
        case .retryStored:
            _ = await store.retryStored()
        }
        link.reconnectNow(reason: "foreground")
        events.attach(to: link)
    }

    /// 服务之间「A 好了 B 该动了」的两根线。只有这个类型同时认识 `store` 与 `link` ——
    /// 放进任一边都要跨层引用。不是「编排写上去了」，而是这个位置就是为了接这种线。
    private func wireCrossServiceTriggers() {
        // 先落成局部量：捕获列表的 `weak` 那一格只接受标识符；也防环 —— 闭包捕获 `self`
        // 会强持有里面每个 class。
        let link = self.link
        let events = self.events
        let credentials = self.credentials

        // 组网刚就绪 → 叫醒连接。那边不排定时器（等外部条件不该烧退避档位），只能靠这一声叫。
        // 「跨进 ready」的判断在这里，不在组网层：组网层只报变了什么，谁该动由编排决定。
        store.onPhaseChanged = { [weak link] old, new in
            guard new == .ready, old != .ready else { return }
            link?.reconnectNow(reason: "mesh-ready")
        }
        // 身份刚变过 → 按现状补做连接那几步。读的是**当前**身份：撤销时 `hasDeviceToken`
        // 已是 false，
        // 于是什么都不做 —— 连接层会把无票当终态自己收成 `.idle`。
        credentials.onIdentityChanged = { [weak credentials, weak link, weak events] in
            guard let credentials, credentials.hasDeviceToken,
                  let link, let events else { return }
            link.activate()
            events.attach(to: link)
        }
    }

    /// 把计划变成调用。一对一映射，不含判断 —— 判断全在 `StartupPlan` 里。
    private func run(_ steps: [StartupStep]) async {
        for step in steps {
            switch step {
            case .attachApprovals:
                approvals.attach(sink: events)
            case .activateLink:
                link.activate()
            case .attachEventStream:
                events.attach(to: link)
            case .launchMesh(let config):
                await store.start(config: config)
            case .reportDamaged:
                store.reportDamagedConfiguration()
            }
        }
    }
}

// MARK: - 回前台的判定

/// 回前台该动哪一步 —— 只由 `MeshPhase` 决定。判定与它的唯一调用点（`sceneActive`）同住：
/// 只有这个类型同时认识「组网阶段」与「App 回到前台」。
enum ForegroundAction: Equatable {
    /// 只探活：节点可能还活着，而重开会把一条正好好的连接杀掉。
    case revive
    /// 按存下来的那份配置重走一次注册。
    case retryStored
}

extension ForegroundAction {

    /// key 被拒不重试：同样的 key 再问一次答案不会变。
    static func of(phase: MeshPhase) -> ForegroundAction {
        if case .failed(.unreachable) = phase { return .retryStored }
        return .revive
    }
}
