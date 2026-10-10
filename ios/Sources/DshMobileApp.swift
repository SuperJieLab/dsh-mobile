import SwiftUI

/// dsh-mobile 的 iPhone 客户端：会话列表 / 会话详情 / 配对 / 审批四个场景的根部，
/// 也是协议纯度的一面镜子 —— 客户端若需要改协议才跑得起来，说明协议没设计对。
///
/// 根部只做一行级接线（R3 决定 6）：创建 `TailnetNode` / `GatewayClient` /
/// `ConnectionStore` 三件并注入，启动与回前台编排全部在 store。node 与 client
/// 是同一实例的两份引用（StateObject 持 store、let 持 client）。
@main
struct DshMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var node: TailnetNode
    @StateObject private var store: ConnectionStore
    private let client: GatewayClient

    init() {
        let node = TailnetNode()
        let client = GatewayClient()
        _node = StateObject(wrappedValue: node)
        _store = StateObject(wrappedValue: ConnectionStore(client: client, node: node))
        self.client = client
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SessionListView(client: client)
                    // 启动编排（兜底激活 → 组网 → 激活内化）全在 store.start。
                    .task { await store.start(config: MeshConfig.load()) }
                    // 回前台探活走 store；WS 重连仍由列表/详情页各自的
                    // onChange(scenePhase) 接管（分工与重构前一致）。
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await store.sceneActive() }
                    }
            }
            // 注在 NavigationStack 根部：navigationDestination 推入的视图
            // （SessionDetailView）在某些时序下拿不到子树注入的环境（真机踩过
            // 「配对成功后进详情页崩溃」）。根部注入覆盖整棵导航树。
            .environmentObject(store)
        }
    }
}
