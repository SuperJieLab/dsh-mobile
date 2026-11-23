/**
 * 会话列表的分组：把「组清单 + 会话行」折成可渲染的若干组。
 *
 * 纯规则 —— 入参就是全部输入，没有状态，不认识网络与视图。组的先后取组清单
 * （宿主给的注册顺序），组内顺序取入参顺序（服务端已按最近发言排好），
 * 不属于任何工作空间的行集中排在最后。
 *
 * 归属只有一处判据：**组流**（`workspace/follow` 的 `baseline.items[].sessionIds`）。
 * 客户端**不按目录路径自己归并** —— 那会让同一批会话在手机与 Mac 的 Web UI 上落进
 * 不同的组，而两边都没有人能立刻看出谁错了。
 *
 * 归属由**组流**给（`WorkspaceStream` 的 `sessionIds`），由调用方折成 `owners` 传进来；
 * 本函数只认那张表，不认行上的任何字段 —— 组流接上之前调用方传空表，于是全部落「未分组」。
 */
import Foundation

/// 列表里的一组：一个工作空间，或最后那个「未分组」。
struct SessionGroup: Identifiable, Equatable {
    /// 组的身份：工作空间的 id；未分组的组是空串（任何工作空间 id 都不可能是空串）。
    let id: String
    /// 组标题；未分组的组没有标题，那句文案归视图。
    let title: String?
    let rows: [SessionRow]

    var isUngrouped: Bool { id == SessionGrouping.ungroupedKey }

    /// 组里有没有会话在跑。
    ///
    /// 折叠之后标题上要靠它留一个痕迹 —— 否则「有东西在动」与「静止的组」在列表上长得一样。
    /// 它在折叠态仍然是准的：折叠只是不画行，`rows` 一直带着全部成员。
    var hasRunning: Bool {
        rows.contains { $0.running }
    }
}

enum SessionGrouping {

    /// 未分组组的身份。
    static let ungroupedKey = ""

    /**
     * 折成组。
     *
     * 组清单里的每一个工作空间都出现，**包括一个会话都没有的**：手机上刚建好的工作空间
     * 里还没有会话（空会话不进列表），那个组是它存在过的唯一证据。
     *
     * @param rows - 已按最近发言降序的派生行（标题已合并）。
     * @param workspaces - 组流给的组清单，顺序即显示顺序。
     * @param owners - 归属表：会话 id → 工作空间 id。不在表里 = 不属于任何工作空间。
     * @returns 各组按清单顺序，未分组（若非空）在最末。
     */
    static func groups(rows: [SessionRow],
                       workspaces: [WorkspaceView],
                       owners: [String: String] = [:]) -> [SessionGroup] {
        let known = Set(workspaces.map(\.workspaceId))
        var byWorkspace: [String: [SessionRow]] = [:]
        var ungrouped: [SessionRow] = []
        for row in rows {
            if let workspaceId = owners[row.id], known.contains(workspaceId) {
                byWorkspace[workspaceId, default: []].append(row)
            } else {
                ungrouped.append(row)
            }
        }
        let groups = workspaces.map { workspace in
            SessionGroup(id: workspace.workspaceId, title: workspace.title,
                         rows: byWorkspace[workspace.workspaceId] ?? [])
        }
        return ungrouped.isEmpty
            ? groups
            : groups + [SessionGroup(id: ungroupedKey, title: nil, rows: ungrouped)]
    }
}
