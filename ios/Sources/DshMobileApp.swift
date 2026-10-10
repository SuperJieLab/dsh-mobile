import SwiftUI

/// dsh-mobile 的 iPhone 客户端：会话列表 / 会话详情 / 配对 / 审批四个场景的根部，
/// 也是协议纯度的一面镜子 —— 客户端若需要改协议才跑得起来，说明协议没设计对
/// （Plan §4.3 Step 4）。
///
/// 根部接线（链路 1 / 链路 3）：启动即拉起组网节点（读沙盒存储决定注册还是
/// 复用）；节点 Running 后把 tailnet session 与网关 tailnet 地址注入 `GatewayClient` ——
/// HTTP 与 WebSocket 整体切进虚拟网，消息层零感知（决定 4）。回前台探活交给节点层。
@main
struct DshMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var node = TailnetNode()
    private let client = GatewayClient(baseURL: GatewayClient.defaultBaseURL)

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SessionListView(client: client)
                    .task {
                        // 配置页的网关地址从启动第一刻就生效（含配对请求）——不能等
                        // 组网 Running：那几秒里配对会打到 defaultBaseURL 的局域网
                        // 兜底地址，换网环境即超时。此刻还没有 tailnet 承载，先用
                        // 普通 session；验证 Running 后经下方根部回调整体切换。
                        if let baseURL = MeshConfig.load().gatewayBaseURL {
                            client.activate(session: .shared, baseURL: baseURL)
                        }
                        await node.launch(config: MeshConfig.load())
                    }
                    // 链路 1 终点：节点验证 Running → 全部流量切 tailnet。激活挂在
                    // 节点层回调上——onChange(of: state) 在同值迁移（running→running）
                    // 时不触发，靠状态 diff 会漏掉激活。
                    .onAppear {
                        node.onVerifiedRunning = { session in
                            guard let baseURL = MeshConfig.load().gatewayBaseURL else { return }
                            client.activate(session: session, baseURL: baseURL)
                        }
                    }
                    // 链路 3：回前台先探活节点（死了如实落 Failed）；WS 重连由
                    // 既有 M3 的 onChange(scenePhase) 接管（列表/详情页各自触发）。
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await node.revive() }
                    }
            }
            // 注在 NavigationStack 根部：navigationDestination
            // 推入的视图（SessionDetailView）在某些时序下拿不到子树注入的环境，配对成功
            // 后首次进详情页即崩（No ObservableObject of type TailnetNode）。根部注入
            // 覆盖整棵导航树，顺带覆盖未来新增的推入页。
            .environmentObject(node)
        }
    }
}
