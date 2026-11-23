/**
 * 会话列表的分组：组的先后、组内顺序、未分组的位置。
 *
 * 纯规则测在这里 —— 不建视图、不连网络、不构造状态对象。判据的形状是「给定组清单、
 * 会话行与归属表，折出来的组是什么」。归属**怎么算**（`workspace/follow` 的
 * `sessionIds`）是流的事，本层只认那张表：客户端不自己按路径归并，否则同一批会话
 * 会在手机与 Web UI 上落进不同的组。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionGroupingTests: XCTestCase {

    private func row(_ id: String, updatedAt: Double = 1, running: Bool = false) -> SessionRow {
        SessionRow(id: id, title: nil, running: running, blank: false, origin: nil, updatedAt: updatedAt)
    }

    private func workspace(_ id: String, _ title: String, sessions: [String] = []) -> WorkspaceView {
        WorkspaceView(workspaceId: id, title: title, sessionIds: sessions)
    }

    func testGroupsFollowTheWorkspaceOrderAndTheUngroupedGroupTrails() {
        let groups = SessionGrouping.groups(
            rows: [row("a1", updatedAt: 3), row("b1", updatedAt: 2), row("x1", updatedAt: 1)],
            workspaces: [workspace("w-b", "B 项目"), workspace("w-a", "A 项目")],
            owners: ["a1": "w-a", "b1": "w-b"])

        XCTAssertEqual(groups.map(\.id), ["w-b", "w-a", SessionGrouping.ungroupedKey],
                       "组的先后取组清单的顺序，未分组必须在最后 —— 按活跃度重排会在这里红")
        XCTAssertEqual(groups[0].rows.map(\.id), ["b1"])
        XCTAssertEqual(groups[1].rows.map(\.id), ["a1"])
        XCTAssertEqual(groups[2].rows.map(\.id), ["x1"])
        XCTAssertEqual(groups[0].title, "B 项目")
        XCTAssertNil(groups[2].title, "未分组的组没有标题 —— 那句文案归视图，判定层不放用户可见的中文")
    }

    func testAWorkspaceWithNoSessionsStillYieldsAnEmptyGroup() {
        let groups = SessionGrouping.groups(
            rows: [row("a1")],
            workspaces: [workspace("w-a", "A"), workspace("w-empty", "还没说过话")],
            owners: ["a1": "w-a"])

        XCTAssertEqual(groups.map(\.id), ["w-a", "w-empty"],
                       "组清单里的工作空间全部出现，包括一行都没有的那个 —— 否则刚建好的工作空间无处可寻")
        XCTAssertTrue(groups[1].rows.isEmpty)
    }

    func testNoUngroupedGroupWhenEverySessionHasOne() {
        let groups = SessionGrouping.groups(
            rows: [row("a1")],
            workspaces: [workspace("w-a", "A")],
            owners: ["a1": "w-a"])

        XCTAssertEqual(groups.map(\.id), ["w-a"], "没有不属于任何工作空间的会话时，不存在未分组这一组")
    }

    func testASessionNamingAnUnknownWorkspaceFallsUngrouped() {
        let groups = SessionGrouping.groups(
            rows: [row("a1")],
            workspaces: [workspace("w-a", "A")],
            owners: ["a1": "w-gone"])

        XCTAssertEqual(groups.map(\.id), ["w-a", SessionGrouping.ungroupedKey],
                       "客户端不为一个没见过的 id 造组")
        XCTAssertEqual(groups[1].rows.map(\.id), ["a1"])
    }

    /// 归属表空着时（组流还没接上）每一行都落未分组 —— 宁可「都在一起」，也不按路径猜。
    func testNoOwnersMeansEverythingIsUngrouped() {
        let groups = SessionGrouping.groups(
            rows: [row("a1"), row("b1")],
            workspaces: [workspace("w-a", "A")])

        XCTAssertEqual(groups.map(\.id), ["w-a", SessionGrouping.ungroupedKey])
        XCTAssertEqual(groups[1].rows.map(\.id), ["a1", "b1"])
    }

    func testTheGroupKeepsTheIncomingOrderInsteadOfReSorting() {
        let groups = SessionGrouping.groups(
            rows: [row("older", updatedAt: 100), row("newer", updatedAt: 200)],
            workspaces: [workspace("w-a", "A")],
            owners: ["older": "w-a", "newer": "w-a"])

        XCTAssertEqual(groups[0].rows.map(\.id), ["older", "newer"],
                       "顺序由服务端排好；客户端二次排序会让两端口径分叉")
    }

    /// 组自己知道有没有东西在跑 —— 折叠之后标题上那个痕迹靠它。
    ///
    /// 判据只落在 `sessions` 上，与折没折叠无关 —— 折叠只是不画行，成员一个不少。所以
    /// 折叠的组「标题上有痕迹」这件事才有数据可依。
    func testAGroupKnowsWhetherAnythingInItIsRunning() {
        let groups = SessionGrouping.groups(
            rows: [row("a1"), row("a2", running: true), row("b1")],
            workspaces: [workspace("w-a", "A"), workspace("w-b", "B")],
            owners: ["a1": "w-a", "a2": "w-a", "b1": "w-b"])

        XCTAssertTrue(groups[0].hasRunning, "组里有一条在跑，整组就算在跑")
        XCTAssertFalse(groups[1].hasRunning, "一条都没跑就是静止的 —— 不能恒真")
    }

    func testAnEmptyGroupIsNotRunning() {
        let groups = SessionGrouping.groups(
            rows: [], workspaces: [workspace("w-a", "A")])

        XCTAssertFalse(groups[0].hasRunning, "空组不能因为「没有任何行在跑」而被算成在跑")
    }
}
