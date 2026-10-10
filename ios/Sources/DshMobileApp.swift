import SwiftUI

/// dsh-mobile 的 iPhone 客户端。M0 的形态：**一个屏 + 一次请求** —— 用一个**真实客户端**再验
/// 一次 Step 3 的协议；若客户端需要改协议才跑得起来，说明协议没设计对（Plan §4.3 Step 4）。
///
/// M8 追加（链路 1 / 链路 3 的根部接线）：启动即拉起组网节点（读沙盒存储决定注册还是
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
                        // 排障诊断：打印本包真实的 ATS 配置（-1022 反复出现，需确认
                        // 设备上的包是否真的带上了 NSAllowsArbitraryLoads）。
                        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity")
                            .flatMap { String(describing: $0) } ?? "nil"
                        FileHandle.standardError.write(Data(">> [app] ATS = \(ats)\n".utf8))
                        // 配置页的网关地址从启动第一刻就生效（含配对请求）——不能等
                        // 组网 Running：那几秒里配对会打到 M0 硬编码兜底地址（真机
                        // T8 实测超时在 192.168.x）。此刻还没有 tailnet 承载，先用
                        // 普通 session；Running 后 onChange 再整体切换。
                        if let baseURL = MeshConfig.load().gatewayBaseURL {
                            client.activate(session: .shared, baseURL: baseURL)
                        }
                        await node.launch(config: MeshConfig.load())
                    }
                    // 链路 1 终点：节点验证 Running → 全部流量切 tailnet。激活挂在
                    // 节点层回调上——onChange(of: state) 在同值迁移（running→running）
                    // 时不触发，靠状态 diff 会漏掉激活（T8 真机实测）。
                    .onAppear {
                        node.onVerifiedRunning = { session in
                            guard let baseURL = MeshConfig.load().gatewayBaseURL else { return }
                            client.activate(session: session, baseURL: baseURL)
                            // 隧道裸探针（T8 排障）：RPC 超时在 100.64.0.1:3081，先用
                            // 同一承载发个最简 GET，把「隧道里任何 HTTP 都不通」与
                            // 「只有 RPC 不通」切开。定位后摘。
                            Task {
                                var req = URLRequest(url: baseURL)
                                req.timeoutInterval = 8
                                do {
                                    let (_, resp) = try await session.data(for: req)
                                    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                    FileHandle.standardError.write(Data(">> [probe] GET \(baseURL) → HTTP \(status)\n".utf8))
                                } catch {
                                    FileHandle.standardError.write(Data(">> [probe] GET \(baseURL) → \(error)\n".utf8))
                                }
                            }
                        }
                    }
                    // 链路 3：回前台先探活节点（死了如实落 Failed）；WS 重连由
                    // 既有 M3 的 onChange(scenePhase) 接管（列表/详情页各自触发）。
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await node.revive() }
                    }
            }
            // 注在 NavigationStack 根部（原注在 SessionListView 上）：navigationDestination
            // 推入的视图（SessionDetailView）在某些时序下拿不到子树注入的环境，配对成功
            // 后首次进详情页即崩（No ObservableObject of type TailnetNode）。根部注入
            // 覆盖整棵导航树，顺带覆盖未来新增的推入页。
            .environmentObject(node)
        }
    }
}
