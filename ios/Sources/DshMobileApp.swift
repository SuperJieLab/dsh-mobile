import SwiftUI

/// dsh-mobile 的 iPhone 客户端入口，也是协议纯度的一面镜子 —— 客户端若需要改协议才跑得
/// 起来，说明协议没设计对。
///
/// 它只做一件事：造一次对象图，交给根视图。选屏、装配目的地、三条 App 级事件都在
/// `RootScreen` —— 它们在 `View` 里成立，而 `App.body` 返回的是 `Scene`。
@main
struct DshMobileApp: App {
    /// 全部基础服务。与进程同寿 —— 见 `AppServices` 头注释里那条前提。
    private let services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootScreen(services: services)
        }
    }
}
