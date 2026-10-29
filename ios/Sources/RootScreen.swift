import SwiftUI

/// 组合根的视图半边：**全应用唯一一处目的地装配**，加一条平台事件的转发。
///
/// **它不驱动启动编排。** 那件事在 `AppServices.start()`（由 `App.init` 开 Task 调）：
/// 编排的语义是「先 A 后 B，必须发生恰好一次」，而视图的语义是「值变了就重画，反复、可丢」。
/// 用后者实现前者的症状全是静默的 —— 视图不渲染就不发生、删一个装饰器就失效、且测不了。
///
/// 它在这里而不在 `App.body` 里，理由是可判的：Observation 的追踪只对 **View 的 body**
/// 有文档保证（`App.body` 返回的是 `Scene`），而屏要读 `store.phase` 这类会变的事实。
///
/// **它不造任何屏级状态**：四个目的地各自造自己的（`SessionListAssembler` 等）。
/// 这里只把服务传下去 —— 屏只发 `Destination` 值，下一屏要什么在这一处接上。
struct RootScreen: View {
    /// 全部基础服务。与进程同寿 —— 它是这个视图唯一的一处依赖来源。
    private let services: AppServices

    @Environment(\.scenePhase) private var scenePhase

    /// 显式 `init`：属性全 `private` 时 memberwise 那一份也是 `private`，`App` 就造不出来。
    init(services: AppServices) {
        self.services = services
    }

    /// 三个装配段要的闭包。**先取局部量再接闭包**：`[weak x]` 那一格只接受一个标识符，
    /// 而 `services` 是属性 —— 拿属性的值得先落成局部量。
    private var hasIdentity: () -> Bool {
        let credentials = services.credentials
        return { credentials.hasDeviceToken }
    }

    private var discardIdentity: () -> Void {
        let client = services.client
        return { client.discardIdentity(reason: .userRequested) }
    }

    private var submitPairingCode: (String) async throws -> Void {
        let client = services.client
        let credentials = services.credentials
        return { code in try await pairDevice(client, code: code, into: credentials) }
    }

    var body: some View {
        NavigationStack {
            // 列表永远是根。前置条件不满足时它只在顶部提示（那条提示由列表自己画）——
            // 正在读会话的人不会被整屏弹走，而修配置从齿轮开始。
            SessionListAssembler(client: services.client,
                                 events: services.events,
                                 store: services.store)
                .navigationDestination(for: Destination.self) { route in
                    switch route {
                    case .session(let session):
                        SessionDetailAssembler(session: session,
                                               client: services.client,
                                               link: services.link,
                                               store: services.store,
                                               approvals: services.approvals)
                    case .settings:
                        SettingsAssembler(store: services.store,
                                          hasIdentity: hasIdentity,
                                          discardIdentity: discardIdentity)
                    case .mesh:
                        MeshSettingsAssembler(store: services.store)
                    case .pairing:
                        PairingAssembler(submit: submitPairingCode,
                                         hasIdentity: hasIdentity,
                                         discardIdentity: discardIdentity)
                    }
                }
        }
        // 回前台：转发给服务，它自己决定探活与重连。**这是全视图唯一的平台事件转发** ——
        // 它不是编排（没有顺序、没有依赖），只是「iOS 告诉 App 的一件事」的接入点。
        // 换成 `UIApplication.didBecomeActiveNotification` 要 `Core/` import UIKit，
        // 且 scene 比 app 细，语义不等价，不值得。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await services.sceneActive() }
        }
    }
}
