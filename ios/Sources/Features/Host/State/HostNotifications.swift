/**
 * 宿主通知的 **App 级分派**：一条 `emit` 进来，算出它该去哪，叫醒订阅者。
 *
 * 为什么不在某一屏里订阅：`deepseek-account/session-expired` 与「目录变了」是宿主的事实，
 * 与哪一屏在前台无关。从前这条订阅挂在会话详情上 —— 停在列表时账号过期，界面上什么都
 * 不发生，用户要等到点进某个会话才知道。
 *
 * 三件东西的寿命因此都提到 App 级：**标志**（`LoginExpiredFlag`）、**分派**（本类）、
 * **订阅**（`AppServices` 在启动那一步接上）。各屏只在自己出现时登记「目录该刷了」，
 * 离屏退订 —— 那是各屏自己的事。
 *
 * 分派规则是纯值（`UpstreamNotification`），本类只负责叫人与留痕。
 */
import Foundation

@MainActor
final class HostNotifications {

    /// 账号失效的标志。由组合根持有并注入两屏 —— 它们读的是**同一个**标志，
    /// 所以详情里点了「知道了」，列表那条也一起收起来。
    private let loginExpired: LoginExpiredFlag

    /// 各屏的听众。按 token 退订 —— 详情每开一次就登记一次，不退就永远多一个。
    private var handlers: [UUID: (UpstreamNotification.Route) -> Void] = [:]

    init(loginExpired: LoginExpiredFlag) {
        self.loginExpired = loginExpired
    }

    /**
     * 登记一个「某条通知到了」的听众。
     *
     * 只派发**三条目录刷新**（模型 / 命令 / 权限）：账号失效归标志，其余没人认领 ——
     * 那两类的处置与本类的听众无关。
     *
     * @returns 退订闭包。调用方（屏）离屏时必须调用它。
     */
    @discardableResult
    func subscribe(_ handler: @escaping (UpstreamNotification.Route) -> Void) -> () -> Void {
        let token = UUID()
        handlers[token] = handler
        return { [weak self] in
            self?.handlers[token] = nil
        }
    }

    /**
     * 一条宿主通知到了。**唯一的分派点**。
     *
     * 分三支：账号失效置标志（与有没有屏在看无关）、三条目录叫醒听众、其余留痕。
     * 留痕是刻意的：这是我们唯一会知道「宿主加了新通知」的地方，而没人认领的通知
     * 在界面上等于没发生。
     */
    func receive(_ name: String) {
        let route = UpstreamNotification.route(name)
        switch route {
        case .accountExpired:
            loginExpired.note()
        case .models, .commands, .permissions:
            for handler in handlers.values { handler(route) }
        case .unhandled:
            Log.warn(Log.Module.gateway, "an upstream notification has no consumer", ["event": name])
        }
    }
}
