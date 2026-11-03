/**
 * 会话列表的一条增量 —— 线上第三种 item 载荷（`{kind:"session-list", change:{…}}`）。
 *
 * 上游的词汇（`api-session/added` 之类）不出网关：网关把它翻成这四支，所以这里只认识自己
 * 的名字。分派是穷举 switch，认不出的返回 `nil` 而不是「默认当成新增」—— 网关将来加一种
 * 时，猜一个比丢掉更坏。
 */
import Foundation

enum SessionListChange: Equatable {

    /// 一行出现或更新。行的形状与列表行同源，但**没有** `createdAt`（上游不带它）。
    case added(SessionSummary)
    case removed(String)
    case status(String, running: Bool)
    case activity(String, updatedAt: Double)

    /// 解一条 `change` 对象；认不出返回 `nil`。
    static func decode(_ payload: JSONValue) -> SessionListChange? {
        switch payload["kind"]?.string {
        case "added":
            guard let row = payload["row"],
                  let id = row["id"]?.string, !id.isEmpty,
                  let updatedAt = row["updatedAt"]?.number,
                  // 两个布尔在契约与网关出站类型里都是**必填**。缺失就丢这一条，
                  // 不补 `false`：补出来的行看起来完全正常，只是在屏幕上说「这个会话不在跑」——
                  // 而真相是这一条我们根本没读懂。
                  let running = row["running"]?.bool,
                  let blank = row["blank"]?.bool
            else { return nil }
            return .added(SessionSummary(
                id: id,
                title: row["title"]?.string,
                createdAt: nil,
                updatedAt: updatedAt,
                running: running,
                blank: blank,
                origin: row["origin"]?.string,
                workspaceId: row["workspaceId"]?.string
            ))
        case "removed":
            guard let id = payload["id"]?.string, !id.isEmpty else { return nil }
            return .removed(id)
        case "status":
            guard let id = payload["id"]?.string, !id.isEmpty,
                  let running = payload["running"]?.bool
            else { return nil }
            return .status(id, running: running)
        case "activity":
            guard let id = payload["id"]?.string, !id.isEmpty,
                  let updatedAt = payload["updatedAt"]?.number
            else { return nil }
            return .activity(id, updatedAt: updatedAt)
        default:
            return nil
        }
    }
}
