/**
 * 「本地与服务端对不上」这件事的**形状与判定** —— 什么时候置位、什么时候清除。
 *
 * 变化原因与 `SessionSync` 不同：编排回答「先取窗口还是先追新增」，这条回答「屏幕上那条告知
 * 该不该出现」，两者变化的原因不同。说给用户听的那句话也不在这里 ——
 * 它在 `Display/SyncText.swift`。
 *
 * 消费者：`SessionSync`（置位与清除的唯一来源）、`SessionDetailView`（读 `notice` 画底栏）。
 */
import Foundation

/// 要显示在底部**固定面**上的一条告知 —— 「本地与服务端对不上」这件事的可见形态。
///
/// 为什么不复用状态行：那一行只出现在 List 的 `Section` footer 里，**随内容滚动** ——
/// 用户往回翻读历史时它在屏幕外，恰是最需要看见的时候看不见，于是屏上看起来一切正常、
/// 只是少了一段内容。告知因此必须挂在不随滚动离开的面上。
struct ResyncNotice: Equatable {

    /// 两种告知 —— 对应的正是分档判据（`ResetReason.invalidatesLocalContent`）的两半。
    enum Kind: Equatable {
        /// 本地那段仍是真的 ⇒ 内容**保住了**，只是更新（或更早的历史）没接上。
        case unresolved
        /// 位置被否定 ⇒ 本地内容**已清空重来**。
        case reset
    }

    let kind: Kind
    let reason: ResetReason
}

/// 告知的置位与清除 —— 判定全在这里，视图只读结果（项目分层红线：视图不写判定）。
///
/// 两条纪律：
/// - **一次「接得上」不清除它** —— 洞还在，界面不该假装没事；
/// - **清除只发生在重新建立**（用户重新同步成功、或离开再进入会话），即 `clear()` 这唯一一处。
struct ResyncNoticeState {

    private(set) var notice: ResyncNotice?

    /// 收下一条判定。只有「对不上」（`.resetRequired`）会置位；接得上与别的失败都不动它。
    mutating func observe(_ verdict: Verdict) {
        guard case .resetRequired(let reason) = verdict else { return }
        notice = ResyncNotice(
            kind: reason.invalidatesLocalContent ? .reset : .unresolved,
            reason: reason
        )
    }

    /// 编排**自己**执行了一次重置 —— 如实记成「已重置」。
    ///
    /// 为什么不复用 `observe(_:)`：那里按 `invalidatesLocalContent` 分档，是给**订阅路径**
    /// （opening / 往回翻）的规则 —— 那种处境下 `.gap` 该保留。而 `sync()` 是用户显式要求的
    /// 「重新同步」，它撞上缺口时**保留无法收敛**（下一次拉到的增量仍接不上），所以它一律重置：
    /// 这里记的是**做过的**，不是**该做的**。
    mutating func didReset(_ reason: ResetReason) {
        notice = ResyncNotice(kind: .reset, reason: reason)
    }

    /// 重新建立 —— 说明唯一的清除点。
    mutating func clear() {
        notice = nil
    }
}
