/**
 * 列表一行的**可渲染形状**，以及三源合成它的那条规则。
 *
 * 为什么要派生：线上的一行（`SessionSummary`）是宿主的事实，而界面上要的标题有**两个
 * 来源** —— 行自带的 `projections.values.title`（冷会话只有它有），与 `session/control`
 * 推来的 `title` 投影（活会话改名后靠它，不必重拉列表）。两处各算一次标题，就会出现
 * 「列表上是旧名、详情里是新名」。
 *
 * 所以标题的合并只在这里发生一次（`SessionRows.make`），状态、视图、分组都读它的结果。
 */
import Foundation

/// 一行：只放界面要读的字段。
///
/// 不带 `agentAvailable` / `formatStatus` / `cwd` 那些：它们参与判定（可见性、迁移提示）
/// 而不参与渲染，留在线上那一层。派生行越窄，「哪个字段从哪来」就越难弄错。
struct SessionRow: Identifiable, Equatable {
    /// 会话 id。与线上那一格同名（`SessionSummary.id` 是它）。
    let id: String
    /// 标题：`titles[id]` 优先，其次行自带的投影，最后 `nil`（界面给「无标题」）。
    let title: String?
    let running: Bool
    let blank: Bool
    let origin: String?
    /// **最后一次用户发言的时间** —— 不是「最后一次事件的时间」。
    let updatedAt: Double
}

enum SessionRows {

    /**
     * 三源合成：线上行 + `session/control` 推来的标题 + （归属由 `SessionOwners` 单独折）。
     *
     * `titles` 覆盖行自带的投影：同一个标题在两处出现时，**投影更新**（它随事件到，
     * 不需要重拉）。`titles` 为空（控制流还没建好）时全部退回行自带的那一格 ——
     * 那时列表仍然有标题，只是活会话改名要等一次重读才看到。
     *
     * @param items - 服务端按 `updatedAt` 降序给的行走。
     * @param titles - 会话 id → 标题（控制流写的）。
     */
    static func make(_ items: [SessionSummary], titles: [String: String]) -> [SessionRow] {
        items.map { item in
            SessionRow(id: item.id,
                       // `??` 的右边是行自带的投影标题；两边都缺就是 `nil`，不是空串。
                       title: titles[item.id] ?? item.title,
                       running: item.running,
                       blank: item.blank,
                       origin: item.origin,
                       updatedAt: item.updatedAt)
        }
    }
}

/**
 * 组清单 → 归属表：会话 id → 工作空间 id。
 *
 * 归属只有这一处判据：组流给的 `items[].sessionIds`。客户端**不按目录路径自己归并** ——
 * 那会让同一批会话在手机与 Mac 的 Web UI 上落进不同的组，而两边都没有人能立刻看出谁错了。
 *
 * 纯函数、无状态：组清单换了就重算一次，没有需要维护的第二份表。
 */
enum SessionOwners {

    /**
     * 折出归属表。
     *
     * 同一个会话出现在两个组里时**后一个胜**：上游的成员表本身不该重叠（一个会话只属于
     * 一个工作空间），出现重叠说明两边的事实不一致；此时「最后读到的那一份」与渲染时
     * 「按组清单顺序画」同向，至少不会让会话同时出现在两处。
     *
     * @param workspaces - 组清单，顺序即显示顺序。
     * @returns 会话 id → 工作空间 id。不在表里 = 不属于任何工作空间（界面画在「未分组」）。
     */
    static func of(_ workspaces: [WorkspaceView]) -> [String: String] {
        var owners: [String: String] = [:]
        for workspace in workspaces {
            for sessionId in workspace.sessionIds {
                owners[sessionId] = workspace.workspaceId
            }
        }
        return owners
    }
}
