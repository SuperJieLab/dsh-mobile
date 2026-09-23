import SwiftUI

/// dsh-mobile 的 iPhone 客户端。M0 的形态：**一个屏 + 一次请求** —— 用一个**真实客户端**再验
/// 一次 Step 3 的协议；若客户端需要改协议才跑得起来，说明协议没设计对（Plan §4.3 Step 4）。
@main
struct DshMobileApp: App {
    private let client = GatewayClient(baseURL: GatewayClient.defaultBaseURL)

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SessionListView(client: client)
            }
        }
    }
}
