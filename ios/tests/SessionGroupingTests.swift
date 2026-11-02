/**
 * 会话列表的分组：组的先后、组内顺序、未分组的位置。
 *
 * 纯规则测在这里 —— 不建视图、不连网络、不构造状态对象。判据的形状是「给定组清单
 * 与会话行，折出来的组是什么」。归属**怎么算**（成员表还是目录路径）是网关的事，
 * 这里只认行上的 `workspaceId`：客户端不自己按路径归并，否则同一批会话会在手机与
 * Web UI 上落进不同的组。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionGroupingTests: XCTestCase {

    private func session(_ id: String, updatedAt: Double = 1, workspace: String? = nil,
                         running: Bool = false) -> SessionSummary {
        SessionSummary(id: id, title: nil, createdAt: 1, updatedAt: updatedAt,
                       running: running, blank: false, origin: nil, workspaceId: workspace)
    }

    private func workspace(_ id: String, _ title: String) -> WorkspaceSummary {
        WorkspaceSummary(id: id, title: title)
    }

    func testGroupsFollowTheWorkspaceOrderAndTheUngroupedGroupTrails() {
        let groups = SessionGrouping.groups(
            sessions: [session("a1", updatedAt: 3, workspace: "w-a"),
                       session("b1", updatedAt: 2, workspace: "w-b"),
                       session("x1", updatedAt: 1)],
            workspaces: [workspace("w-b", "B 项目"), workspace("w-a", "A 项目")])

        XCTAssertEqual(groups.map(\.id), ["w-b", "w-a", SessionGrouping.ungroupedKey],
                       "组的先后取组清单的顺序，未分组必须在最后 —— 按活跃度重排会在这里红")
        XCTAssertEqual(groups[0].sessions.map(\.id), ["b1"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["a1"])
        XCTAssertEqual(groups[2].sessions.map(\.id), ["x1"])
        XCTAssertEqual(groups[0].title, "B 项目")
        XCTAssertNil(groups[2].title, "未分组的组没有标题 —— 那句文案归视图，判定层不放用户可见的中文")
    }

    func testAWorkspaceWithNoSessionsStillYieldsAnEmptyGroup() {
        let groups = SessionGrouping.groups(
            sessions: [session("a1", workspace: "w-a")],
            workspaces: [workspace("w-a", "A"), workspace("w-empty", "还没说过话")])

        XCTAssertEqual(groups.map(\.id), ["w-a", "w-empty"],
                       "组清单里的工作空间全部出现，包括一行都没有的那个 —— 否则刚建好的工作空间无处可寻")
        XCTAssertTrue(groups[1].sessions.isEmpty)
    }

    func testNoUngroupedGroupWhenEverySessionHasOne() {
        let groups = SessionGrouping.groups(
            sessions: [session("a1", workspace: "w-a")],
            workspaces: [workspace("w-a", "A")])

        XCTAssertEqual(groups.map(\.id), ["w-a"], "没有不属于任何工作空间的会话时，不存在未分组这一组")
    }

    func testASessionNamingAnUnknownWorkspaceFallsUngrouped() {
        let groups = SessionGrouping.groups(
            sessions: [session("a1", workspace: "w-gone")],
            workspaces: [workspace("w-a", "A")])

        XCTAssertEqual(groups.map(\.id), ["w-a", SessionGrouping.ungroupedKey],
                       "客户端不为一个没见过的 id 造组")
        XCTAssertEqual(groups[1].sessions.map(\.id), ["a1"])
    }

    func testTheGroupKeepsTheIncomingOrderInsteadOfReSorting() {
        let groups = SessionGrouping.groups(
            sessions: [session("older", updatedAt: 100, workspace: "w-a"),
                       session("newer", updatedAt: 200, workspace: "w-a")],
            workspaces: [workspace("w-a", "A")])

        XCTAssertEqual(groups[0].sessions.map(\.id), ["older", "newer"],
                       "顺序由服务端排好；客户端二次排序会让两端口径分叉")
    }

    /// 组自己知道有没有东西在跑 —— 折叠之后标题上那个痕迹靠它。
    ///
    /// 判据只落在 `sessions` 上，与折没折叠无关 —— 折叠只是不画行，成员一个不少。所以
    /// 折叠的组「标题上有痕迹」这件事才有数据可依。
    func testAGroupKnowsWhetherAnythingInItIsRunning() {
        let groups = SessionGrouping.groups(
            sessions: [session("a1", workspace: "w-a"),
                       session("a2", workspace: "w-a", running: true),
                       session("b1", workspace: "w-b")],
            workspaces: [workspace("w-a", "A"), workspace("w-b", "B")])

        XCTAssertTrue(groups[0].hasRunning, "组里有一条在跑，整组就算在跑")
        XCTAssertFalse(groups[1].hasRunning, "一条都没跑就是静止的 —— 不能恒真")
    }

    func testAnEmptyGroupIsNotRunning() {
        let groups = SessionGrouping.groups(
            sessions: [], workspaces: [workspace("w-a", "A")])

        XCTAssertFalse(groups[0].hasRunning, "空组不能因为「没有任何行在跑」而被算成在跑")
    }
}
