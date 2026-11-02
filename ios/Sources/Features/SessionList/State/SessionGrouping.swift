/**
 * 会话列表的分组：把「组清单 + 会话行」折成可渲染的若干组。
 *
 * 纯规则 —— 入参就是全部输入，没有状态，不认识网络与视图。组的先后取组清单
 * （宿主给的注册顺序），组内顺序取入参顺序（服务端已按最近发言排好），
 * 不属于任何工作空间的行集中排在最后。
 *
 * 归属只有一处判据：行上的 `workspaceId`。客户端**不按目录路径自己归并** —— 那会让
 * 同一批会话在手机与 Mac 的 Web UI 上落进不同的组，而两边都没有人能立刻看出谁错了。
 */
import Foundation

/// 列表里的一组：一个工作空间，或最后那个「未分组」。
struct SessionGroup: Identifiable, Equatable {
    /// 组的身份：工作空间的 id；未分组的组是空串（任何工作空间 id 都不可能是空串）。
    let id: String
    /// 组标题；未分组的组没有标题，那句文案归视图。
    let title: String?
    let sessions: [SessionSummary]

    var isUngrouped: Bool { id == SessionGrouping.ungroupedKey }
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
     * @param sessions - 已按最近发言降序的行。
     * @param workspaces - 宿主给的工作空间清单，顺序即显示顺序。
     * @returns 各组按清单顺序，未分组（若非空）在最末。
     */
    static func groups(sessions: [SessionSummary], workspaces: [WorkspaceSummary]) -> [SessionGroup] {
        let known = Set(workspaces.map(\.id))
        var byWorkspace: [String: [SessionSummary]] = [:]
        var ungrouped: [SessionSummary] = []
        for session in sessions {
            if let workspaceId = session.workspaceId, known.contains(workspaceId) {
                byWorkspace[workspaceId, default: []].append(session)
            } else {
                ungrouped.append(session)
            }
        }
        let groups = workspaces.map { workspace in
            SessionGroup(id: workspace.id, title: workspace.title,
                         sessions: byWorkspace[workspace.id] ?? [])
        }
        return ungrouped.isEmpty
            ? groups
            : groups + [SessionGroup(id: ungroupedKey, title: nil, sessions: ungrouped)]
    }
}
