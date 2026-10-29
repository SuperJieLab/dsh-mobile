import SwiftUI

/// dsh-mobile 的 iPhone 客户端入口：造一次对象图、**开一个 Task 让服务自己启动**，然后把
/// 图交给根视图。
/// 启动写在这里而不是某个视图的 `.task`：编排的语义是「必须发生恰好一次」，
/// 与「视图求值」无关。
@main
struct DshMobileApp: App {
    /// 全部基础服务。与进程同寿 —— 见 `AppServices` 头注释里那条前提。
    private let services = AppServices()

    init() {
        // 必须落成局部量：`Task { }` 的闭包不能捕获 `self`（`App` 的初始化还没完成，
        // 而且那样会把整张对象图按值复制一份）。
        let services = self.services
        Task { await services.start() }
    }

    var body: some Scene {
        WindowGroup {
            RootScreen(services: services)
        }
    }
}
