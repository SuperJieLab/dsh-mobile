/**
 * 一条宿主通知（`$events` 的 `emit`）该去哪 —— **判定只在这里**。
 *
 * 与 `PendingEventRouter` 同一个手法：判定抽成纯值才能单独测。写在容器的闭包里的话，
 * 它要造 client / link / store 才能起，本机一条判据都跑不了。
 *
 * 名字来自上游（`host/events` 的订阅表），不是自造的：这一格与 `event` 在 `waterfall`
 * 里是同一类东西 —— 上游的事件名。
 */
import Foundation

enum UpstreamNotification {

    /// 四条去路 + 「没人认领」。
    enum Route: Equatable {
        /// `llm/models-updated`：模型目录变了。
        case models
        /// `commands/change`：命令目录变了（插件装卸）。
        case commands
        /// `permission-presets/catalog-changed`：预设目录变了。
        case permissions
        /// `deepseek-account/session-expired`：账号过期。
        case accountExpired
        /// 其余 —— 不猜它属于谁。
        case unhandled
    }

    static func route(_ name: String) -> Route {
        switch name {
        case "llm/models-updated": return .models
        case "commands/change": return .commands
        case "permission-presets/catalog-changed": return .permissions
        case "deepseek-account/session-expired": return .accountExpired
        default: return .unhandled
        }
    }
}
