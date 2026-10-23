import SwiftUI

/// dsh-mobile 的 iPhone 客户端：会话列表 / 会话详情 / 配对 / 审批四个界面的根部，
/// 也是协议纯度的一面镜子 —— 客户端若需要改协议才跑得起来，说明协议没设计对。
///
/// 根部只做接线：node / client / store / link / events 各一件并注入；启动编排在 store，
/// 两个重连点（回前台、组网就绪）在根部。node 与 client
/// 是同一实例的两份引用（StateObject 持 store、let 持 client）。
@main
struct DshMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var node: TailnetNode
    @StateObject private var store: MeshStore
    /// 到网关的常驻连接 —— App 级、唯一实例。会话详情只在它上面开关流。
    @StateObject private var link: GatewayHost
    private let client: GatewayClient
    /// 连接级事件流的收端 —— App 级，与连接同寿。两个消费方：待答表（清空）与
    /// 会话列表（逐个事件 + 代次重拉）。
    private let events: ConnectionEventStream
    /// 待答审批 —— App 级、唯一实例。不随任何一屏生死：停在会话列表时它照样在收。
    @StateObject private var approvals: ApprovalStore

    init() {
        let node = TailnetNode()
        let client = GatewayClient()
        _node = StateObject(wrappedValue: node)
        _store = StateObject(wrappedValue: MeshStore(client: client, node: node))
        _link = StateObject(wrappedValue: GatewayHost(client: client))
        self.client = client
        let events = ConnectionEventStream()
        self.events = events
        _approvals = StateObject(wrappedValue: ApprovalStore(
            answerer: GatewayApprovalAnswerer(client: client)
        ))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SessionListView(client: client, link: link, events: events)
                    // 启动编排（兜底激活 → 组网 → 激活内化）全在 store.start。
                    // 配置读坏了不交给节点：空配置只会换来一个误导的「不可达」。
                    .task {
                        if case .damaged = MeshConfig.read() {
                            store.reportDamagedConfiguration()
                        } else {
                            await store.start(config: MeshConfig.load())
                        }
                    }
                    // 连接常驻：App 一到前台就要一条。此刻可以一条流都没有 ——
                    // 停在会话列表时它照样连着（心跳也照样判活）。
                    // 事件流同时登记：它不绑会话，停在列表页也正是要看「别的设备上发生了什么」。
                    .task {
                        link.activate()
                        events.attach(to: link)
                        // 两处接线：待答调用的两条货物、源失效清空。
                        approvals.attach(events: events)
                    }
                    // 两个重连点放在根部而不是某一屏：这都是 App 级事件，关掉会话详情
                    // 它们照样该发生。
                    // ① 回前台立即重连 —— 上游「恢复立即试」的复现；已就绪 / 握手中的
                    //    连接不受影响，不会叠加。
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await store.sceneActive() }
                        link.reconnectNow()
                        // 被终态拒绝收起的那条流只在这一刻重建：重试同一个拒绝没有意义。
                        // 它幂等 —— 正常情况 `attach` 的闸会直接放行。
                        events.attach(to: link)
                    }
                    // ② 组网就绪即重连（与列表「就绪即首载」对称）：connecting 期间连接
                    //    在退避循环里空转（端点不存在），就绪此刻不必再等下一轮退避。
                    .onChange(of: store.phase) { _, phase in
                        guard case .ready = phase else { return }
                        link.reconnectNow()
                    }
            }
            // 注在 NavigationStack 根部：navigationDestination 推入的视图
            // （SessionDetailView）在推入那一刻读不到子树注入的环境 —— 根部注入
            // 才覆盖整棵导航树。
            .environmentObject(store)
            .environmentObject(approvals)
        }
    }
}
