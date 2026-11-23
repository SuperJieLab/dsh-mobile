/**
 * 「登录已失效」的一次性提示。
 *
 * **只提示，不动凭证**：凭证该不该清由身份域判断（那是 401 闸门的活），而这条事件只是
 * 宿主告诉我们「这次调用的账号过期了」。在这里顺手删票会让「重连一次就好」变成「重新配对」。
 *
 * 单独一个可观察小类，因为它是 **App 级**的：由组合根持有、列表与详情共读同一个实例
 * —— 详情里点了「知道了」，列表那条也一起收。挂在任一屏的容器上，另一屏就收不到。
 */
import Foundation

@MainActor
@Observable
final class LoginExpiredFlag {
    private(set) var isShowing = false

    /// 收到事件就置位。重复到达不叠第二条 —— 它是一个「有事」的标志，不是列表。
    func note() {
        guard !isShowing else { return }
        isShowing = true
        Log.warn(Log.Module.gateway, "the account session expired — the gateway will keep refusing until it is refreshed")
    }

    /// 用户看过一次就收起来。
    func dismiss() {
        isShowing = false
    }
}
