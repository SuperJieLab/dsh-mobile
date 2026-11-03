import SwiftUI

/// 组合根的视图半边：**全应用唯一一处目的地装配**，加一条平台事件的转发。
/// **它不驱动启动编排** —— 那件事在 `AppServices.start()`：编排的语义是「先 A 后 B，恰好
/// 一次」，而视图的语义是「值变了就重画，反复、可丢」。
/// 它在这里而不在 `App.body`：Observation 的追踪只对 **View 的 body** 有文档保证。
/// **它不造任何屏级状态**：四个目的地各自造自己的，这里只把服务传下去。唯一持有的是
/// 导航路径本身 —— 栈推进是根的职责，不是某一屏的。
struct RootScreen: View {
    /// 全部基础服务。与进程同寿 —— 它是这个视图唯一的一处依赖来源。
    private let services: AppServices

    /// 导航路径。列表建完会话要能主动推进一屏（`NavigationLink` 只表达"点了这一行"），
    /// 所以栈由根持、以绑定形式传下去。
    @State private var path: [Destination] = []

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
        NavigationStack(path: $path) {
            // 列表永远是根。前置条件不满足时它只在顶部提示（那条提示由列表自己画）——
            // 正在读会话的人不会被整屏弹走，而修配置从齿轮开始。
            SessionListAssembler(client: services.client,
                                 events: services.events,
                                 store: services.store,
                                 navigate: { path.append($0) })
                .navigationDestination(for: Destination.self) { route in
                    switch route {
                    case .session(let sessionId, let title):
                        SessionDetailAssembler(sessionId: sessionId,
                                               title: title,
                                               client: services.client,
                                               link: services.link,
                                               store: services.store,
                                               approvals: services.approvals)
                    case .settings:
                        SettingsAssembler(store: services.store,
                                          logFile: services.logFile,
                                          telemetryStore: services.telemetryStore,
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
