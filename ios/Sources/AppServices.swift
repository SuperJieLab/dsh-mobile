import Foundation

/// 这台 App 的全部基础服务：一次造好，之后只被传递、不被修改。
///
/// **它不是状态。** 字段全是 `let`，没有任何东西改它；观察也不落在它身上 —— 视图读
/// `services.store.phase` 时，追踪落在 `MeshStore` 内部，中间隔几层非可观察的类型都无所谓。
/// `@State` 的两个含义（这个视图自己的可变数据 / 参与观察）它一个都不占，所以不标。
///
/// **只造一次的保证来自入口语义**：`App` 由运行时实例化一次，它的存储属性因此与进程同寿。
/// 这条没有写进 Apple 的文档，是实践事实 —— 写在这里，因为它是这个形状成立的前提。
///
/// **构造顺序即依赖**：`client` 要读 `store` 的隧道产物，`link` 要 `client` 的票。
///
/// **构造里没有网络、没有启动、没有配置读写** —— 那些都由视图的 `.task` 驱动。唯一一处
/// 构造期 I/O 是 `credentials` 的首次初始化：它是单例，`init` 读一次设备凭证。
/// 这一处是**有意的**，理由与代价都写明：
/// - 身份是启动第一帧就要知道的事实。改成启动后再读，首帧会先按「未配对」画一屏
///   （浮条闪一下再消失），而用户要的是「打开就知道配没配」。
/// - 代价是它让「构造纯」这条纪律破了一个洞，且这条例外**抓不到**：`SecretFile.read`
///   的缺席是常态、不记日志，所以「构造两次看日志有没有 I/O」这种观测手段看不见它。
///   ⇒ 它靠这条注释与评审守，不靠判据。要改的话，正解是让 `CredentialStore` 在 `.task`
///   里读、首帧按「未知」画，那是一次独立的取舍。
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

    /// 启动：**进程级一次**，由 `App.init` 开一个 Task 调。
    ///
    /// 它做两件事、分两个阶段：
    /// 1. **接线**（同步，先做）：本轮之前这些依赖是靠 `RootScreen` 的
    ///    `.onChange(of: store.phase)` / `.task(id: hasDeviceToken)` 表达的 ——
    ///    那是渲染的副作用，视图不求值就不会发生。接线放在这里，与渲染无关。
    /// 2. **动作**（按 `StartupPlan` 走，逐条同步执行，组网那一步 await）。
    ///
    /// **为什么等组网出结论**：它是整条链的底座。没有地址，`activateLink` 只是把
    /// `active` 置真、`attachEventStream` 只是登记一条开不出去的流 —— 三步都等不到
    /// 任何数据。所以「先组网、再连接」不该只是列表里的先后，执行上也要真的等：
    /// 顺序与「等」是同一件事的两个说法。
    ///
    /// **等多久不影响界面**：`start()` 跑在 `App.init` 开的 Task 里，没有人在等它返回；
    /// 期间 UI 照常按 `store.phase` 画「等组网…」。代价只有一个 —— 组网三次尝试全失败时
    /// 要等满（约 49s）才走到连接那几步，而那段时间连接本来就无处可去。
    ///
    /// **等待期间身份到来不受影响**：`credentials.onIdentityChanged` 是独立回调，
    /// 不被这个 await 挡住，它自己会 `activate` + `attach`。
    func start() async {
        wireCrossServiceTriggers()

        let steps = StartupPlan.steps(
            hasIdentity: credentials.hasDeviceToken,
            config: MeshConfig.read()
        )
        await run(steps)
    }

    /// 回前台：按现状决定探活还是重试（组网）+ 立刻要一次连接 + 重建被终态拒绝的流。
    ///
    /// **`revive` 与 `retry` 的选择住在这里**，因为只有这个类型同时认识两样输入：
    /// `store.phase`（组网域的事实）与「App 回到前台」（平台事件）。判定本身是纯函数
    /// `ForegroundAction.of(phase:)` —— 放在别处要么让它依赖平台事件，要么让判定无处可测。
    ///
    /// 为什么 `.failed(.unreachable)` 要重试而不是只探活：探活对一条本来就不通的节点没有意义，
    /// 而「用户回来了」是重新尝试最可靠的信号 —— 比后台定时器省电，时机也更准（后台网络受限，
    /// 失败还会白白消耗次数）。key 被拒不重试：同样的 key 再问一次答案不会变。
    ///
    /// 三件事的顺序有依赖：探活可能把组网从 failed 拉回来，那会让 `onPhaseReady` 再触发一次
    /// 重连；而这里的 `reconnectNow` 覆盖「组网一直好着、只是连接断了」那一路。两者都幂等
    /// （各自的闸挡住重复），所以顺序不影响正确性。
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

    /// 服务之间「A 好了 B 该动了」的两根线。
    ///
    /// 为什么在这里：只有这个类型同时认识 `store` 与 `link`。放进任一边都要跨层引用
    /// （`Gateway` 不认识 `MeshNetwork`，见 `RULES` 的依赖方向）。所以不是「编排写在
    /// 上层」，而是**这个上层的位置就是为了接这种线而存在的**。
    private func wireCrossServiceTriggers() {
        // 先落成局部量：捕获列表的 `weak` 那一格只接受一个标识符，而这些都是属性。
        // 同时也是防环的必要条件 —— 闭包若捕获 `self`（值类型的一段拷贝），它会把
        // 里面的每个 class 引用一起强持有，而这些闭包又正被那些 class 持有。
        let link = self.link
        let events = self.events
        let credentials = self.credentials

        // 组网刚就绪 → 叫醒连接。没有它，连接会一直停在 `.awaitingMesh` ——
        // 那边不排定时器（等外部条件不该烧退避档位），只能靠这一声叫。
        store.onPhaseReady = { [weak link] in
            link?.reconnectNow(reason: "mesh-ready")
        }
        // 身份刚变过 → 按现状补做连接那几步。
        //
        // 回调体读的是**当前**身份，不是「变成了什么」：撤销时 `hasDeviceToken` 已是 false，
        // 于是什么都不做 —— 连接层会把无票当终态自己收成 `.idle`，这里不必替它收。
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
