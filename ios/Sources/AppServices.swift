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
    /// 端上遥测的订阅者。造好但不注册 —— 注册发生在 `start()` 里，与其余启动动作同处。
    let telemetry: MetricKitReporter
    /// 日志的落盘口。诊断包读它取「上一次跑的尾巴」。
    let logFile: LogFile
    /// 遥测落盘。诊断包读它取最近几份 payload。
    let telemetryStore: TelemetryStore
    /// 写操作的审计。设置页的「操作历史」读它。
    let auditLog: AuditLog

    init() {
        // 落盘在这里装，是构造期唯一的例外：越早越好，而晚装的每一行都只活在控制台里 ——
        // 控制台在断开之后什么都没有，而断开之后正是要查的时候。
        let logFile = LogFile(url: LogFile.defaultURL())
        Log.installFileLog(logFile)

        let node = TailnetNode()
        let store = MeshStore(node: node)
        let credentials = CredentialStore.shared
        let auditLog = AuditLog(directory: AuditLog.defaultDirectory())
        let client = RpcClient(
            session: { [weak store] in store?.route?.session ?? .shared },
            baseURL: { [weak store] in store?.route?.baseURL },
            credentials: credentials,
            audit: auditLog
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
        let telemetryStore = TelemetryStore(directory: TelemetryStore.defaultDirectory())
        let telemetry = MetricKitReporter(store: telemetryStore)

        self.store = store
        self.credentials = credentials
        self.client = client
        self.link = link
        self.events = events
        self.approvals = approvals
        self.telemetry = telemetry
        self.logFile = logFile
        self.telemetryStore = telemetryStore
        self.auditLog = auditLog
    }

    // MARK: - 编排

    /// 启动：**进程级一次**，由 `App.init` 开一个 Task 调。两个阶段：
    /// 1. **接线**（同步）：不能靠视图的 `.onChange` / `.task(id:)` 表达 —— 那是渲染的副作用。
    /// 2. **动作**（按 `StartupPlan` 走，组网那一步 await）。
    /// 等组网出结论：没有地址，后面几步都等不到任何数据。顺序与「等」是同一件事。
    func start() async {
        // 遥测先注册：它不依赖任何别的服务，而晚注册会让这一轮已投递的 payload 等下一次。
        // 放在这里而不是 `init`：构造期只该有「造对象」这一件事。
        telemetry.start()
        wireCrossServiceTriggers()

        let steps = StartupPlan.steps(
            hasIdentity: credentials.hasDeviceToken,
            config: MeshConfig.read()
        )
        await run(steps)
    }

    /// 回前台：先让组网自己恢复，能发才去要一次连接。
    ///
    /// 只重连不足以恢复：回前台那一刻底层 socket 已死（`Code=57`），此后 288 次重连没有一次
    /// 成功 —— 重连换的是 TCP，坏的是隧道。换掉整个节点实例那次两秒就恢复。
    /// 「怎么判断、怎么修」全在 `MeshStore.ensureReachable`，这里只说「回到前台了」。
    func sceneActive() async {
        if await store.ensureReachable() {
            link.reconnectNow(reason: "foreground")
        }
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
        // 组网换了产物 → 换一条连接。**不能并进上面那一条**：换代时阶段可能本来就是 ready，
        // 而 `reconnectNow` 在 ready 上是空操作（它答的是「别等退避」，不是「换一条」）。
        store.onRouteReplaced = { [weak link] in
            link?.replaceConnection(reason: "tunnel-replaced")
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

