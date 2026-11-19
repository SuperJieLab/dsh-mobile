/**
 * 上游事件的解释：`api-session` 那几类事件 → 列表变化。
 *
 * 这一层原先在网关（`upstream/session-events.ts` 的 `sessionListChangeOf` / `sessionListRowOf`），
 * 本期搬回客户端：`$events` 把 `emit` 原样转发，网关不再解释事件名（R5）。搬过来之后
 * 两端对「一个事件意味着什么」只有一份答案 —— 而这份答案本来就是上游给的，不是我们定的。
 *
 * **`workspaceId` 这里给 `nil`**：网关旧实现用一份「会话 → 工作空间」的映射补它，那份映射
 * 随 `workspace` 端口一起退出了流层。行里没有这个字段，列表按工作空间过滤时要另找来源 ——
 * 这是搬移带来的已知缺口，记在方案的分期里。
 */
import Foundation

enum SessionListEvents {

    /// 一条 `emit` 的载荷 → 列表变化。认不出的事件（不是 `api-session` 那几类、或参数不对）返回 `nil`。
    static func changeOf(event: String, args: JSONValue) -> SessionListChange? {
        guard let items = args.array else { return nil }
        switch event {
        case "api-session/added":
            guard let row = items.first, let summary = summaryOf(row) else { return nil }
            return .added(summary)
        case "api-session/removed":
            guard let id = items.first?.string, !id.isEmpty else { return nil }
            return .removed(id)
        case "api-session/status":
            guard let id = items.first?.string, !id.isEmpty,
                  items.count > 1, let running = items[1].bool
            else { return nil }
            return .status(id, running: running)
        case "api-session/activity":
            guard let id = items.first?.string, !id.isEmpty,
                  items.count > 1, let updatedAt = items[1].number
            else { return nil }
            return .activity(id, updatedAt: updatedAt)
        default:
            return nil
        }
    }

    /// 上游的会话摘要 → 列表行。
    ///
    /// 与网关旧实现（`sessionListRowOf`）逐字段对齐：`sessionId` 是 id、`running` / `blank`
    /// 缺席按 `false`（上游这两个是布尔，网关就是这么折的）；标题在
    /// `projections.values.title` 那一格。
    private static func summaryOf(_ host: JSONValue) -> SessionSummary? {
        guard let id = host["sessionId"]?.string, !id.isEmpty,
              let updatedAt = host["updatedAt"]?.number
        else { return nil }
        return SessionSummary(
            id: id,
            title: host["projections"]?["values"]?["title"]?.string,
            createdAt: nil,
            updatedAt: updatedAt,
            running: host["running"]?.bool ?? false,
            blank: host["blank"]?.bool ?? false,
            origin: host["origin"]?.string,
            workspaceId: nil
        )
    }
}
