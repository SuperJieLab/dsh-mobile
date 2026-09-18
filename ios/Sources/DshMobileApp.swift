import SwiftUI

/// dsh-mobile 的 iPhone 客户端。
///
/// M1 的形态是刻意的：**一个屏 + 一次请求**。它存在的意义不是「有个 App」，
/// 而是用一个**真实客户端**再验一次 Step 3 的协议 ——
/// 若客户端需要改协议才跑得起来，说明协议没设计对（Plan §4.3 Step 4）。
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
