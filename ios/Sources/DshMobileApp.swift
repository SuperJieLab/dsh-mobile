import SwiftUI

/// dsh-mobile 的 iPhone 客户端入口，也是协议纯度的一面镜子 —— 客户端若需要改协议才跑得
/// 起来，说明协议没设计对。
///
/// 它做两件事：造一次对象图、**开一个 Task 让服务自己启动**，然后把图交给根视图。
///
/// 启动写在这里而不是某个视图的 `.task`：编排的语义是「必须发生恰好一次」，与「视图求值」
/// 无关 —— 视图不渲染（后台、被 sheet 盖住）时编排仍必须发生。所以触发点在进程入口，
/// 而**不 await**：组网多久才好由它自己重试，UI 该画什么画什么，就绪了按状态变化自己更新。
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
