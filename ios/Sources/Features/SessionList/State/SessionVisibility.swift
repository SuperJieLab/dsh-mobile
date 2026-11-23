/**
 * 会话列表的可见性规则：给定一行摘要，回答「这一行显示不显示」。纯函数、无状态。
 *
 * `blank` 是还没有任何 turn 的候补新会话；`origin == "subagent"` 是别的会话的子会话。
 * **网关没有对应的第二条规则**：`session/list` 是转发宿主的 `list`，可见性（含「没有 `cwd`
 * 的会话不列」）全在宿主那一侧。这里这一条是客户端自己的取舍（`blank` / `subagent`），
 * 两边各管一件事，不重叠。
 */
import Foundation

enum SessionVisibility {
    /// 这一行该显示吗。只拦 `blank` 与 `subagent` 两个值，其余一律显示。
    static func isVisible(_ session: SessionSummary) -> Bool {
        if session.blank { return false }
        return session.origin != "subagent"
    }
}
