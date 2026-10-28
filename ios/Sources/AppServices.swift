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
}
