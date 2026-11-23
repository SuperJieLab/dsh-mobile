/**
 * 会话列表的一条增量 —— **列表状态与合并规则认识的那四支**。
 *
 * 从线上文本到这里的那一步在 `SessionListEvents`（它读上游的 `api-session/` 那几类事件名）；
 * 本类型只管「变化有哪几种」，因此没有解码器。
 */
import Foundation

enum SessionListChange: Equatable {

    /// 一行出现或更新。行的形状与列表行同源 —— 标题在 `projections` 里。
    case added(SessionSummary)
    case removed(String)
    case status(String, running: Bool)
    case activity(String, updatedAt: Double)
}
