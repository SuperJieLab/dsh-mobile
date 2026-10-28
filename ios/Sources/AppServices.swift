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
/// 构造里只存字段与接闭包，不读盘、不启动、不发请求 —— 它可能被多造几次而没人察觉，
/// 副作用会在那几次里落到磁盘上。
///
/// 内层闭包弱引用彼此，因此这里持有谁都不会成环。
@MainActor
struct AppServices {
    let node: TailnetNode
    /// 组网域：隧道的判据与产物都住它，两条链路向它取。
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

        self.node = node
        self.store = store
        self.credentials = credentials
        self.client = client
        self.link = link
        self.events = events
        self.approvals = approvals
    }
}
