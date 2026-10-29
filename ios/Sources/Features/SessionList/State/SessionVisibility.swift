/**
 * 会话列表的可见性规则：给定一行摘要，回答「这一行显示不显示」。纯函数、无状态。
 *
 * `blank` 是还没有任何 turn 的候补新会话；`origin == "subagent"` 是别的会话的子会话。
 * 网关另有一条「没有 cwd 的会话不列」，在适配器里 —— 不是同一处判断。
 */
import Foundation

enum SessionVisibility {
    /// 这一行该显示吗。只拦 `blank` 与 `subagent` 两个值，其余一律显示。
    static func isVisible(_ session: SessionSummary) -> Bool {
        if session.blank { return false }
        return session.origin != "subagent"
    }
}
