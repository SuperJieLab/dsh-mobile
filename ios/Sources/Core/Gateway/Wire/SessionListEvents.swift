/**
 * 上游事件的解释：`api-session` 那几类事件 → 列表变化。
 *
 * 解释放在客户端：`$events` 把 `emit` 原样转发，网关不解释事件名。于是两端对
 * 「一个事件意味着什么」只有一份答案 —— 而这份答案本来就是上游给的，不是我们定的。
 *
 * **行里没有归属**：上游的摘要本来就不带 `workspaceId`，归属由组流给（`workspace/follow`
 * 的 `items[].sessionIds`）。这条事件只负责「这一行的事实变了」，不参与分组。
 */
import Foundation

enum SessionListEvents {

    /// 一条 `emit` 的载荷 → 列表变化。
    /// 认不出的事件（不是 `api-session` 那几类、或参数不对）返回 `nil`。
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

    /// 上游的会话摘要 → 列表行。**与 `session/list` 的行同源同形** —— 两处各解一遍时，
    /// 其中一处迟早在某个字段上分家，而症状是「拉来的行」与「事件推来的行」长得不一样。
    private static func summaryOf(_ host: JSONValue) -> SessionSummary? {
        guard let sessionId = host["sessionId"]?.string, !sessionId.isEmpty,
              let updatedAt = host["updatedAt"]?.number,
              // 两个布尔与 `agentAvailable` 在上游都是必填。缺失就丢这一条，
              // 不补 `false`：补出来的行看起来完全正常，只是在屏幕上说了错的话。
              let running = host["running"]?.bool,
              let blank = host["blank"]?.bool,
              let agentAvailable = host["agentAvailable"]?.bool
        else { return nil }
        return SessionSummary(
            sessionId: sessionId,
            updatedAt: updatedAt,
            running: running,
            blank: blank,
            agentAvailable: agentAvailable,
            formatStatus: host["formatStatus"]?.string,
            parentSessionId: host["parentSessionId"]?.string,
            origin: host["origin"]?.string,
            cwd: host["cwd"]?.string,
            projections: projectionsOf(host["projections"])
        )
    }

    /// 投影块：`{kind, asOfSeq, values}`。整格解不出就当没有 —— 标题缺席是契约的一部分。
    private static func projectionsOf(_ payload: JSONValue?) -> SessionProjections? {
        guard let payload, payload.object != nil else { return nil }
        return SessionProjections(
            kind: payload["kind"]?.string,
            asOfSeq: payload["asOfSeq"]?.number.map(Int.init),
            values: payload["values"]
        )
    }
}
