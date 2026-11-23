/**
 * 会话列表的增量：一条变更怎么落到一串行上。
 *
 * 只断**合并**（变更 → 新的行序）：纯值、不碰网络与视图，于是「顺序只有一条规则」
 * 能在这里被钉住。线上载荷 → `SessionListChange` 的那一步在 `SessionListEventsTests`
 * （它读的是上游的事件名）。
 *
 * 合并的另半边（在途期间记账、落地后重放）在 `SessionListStateTests`：那需要一条
 * 能被停住的取数，不是纯值类型的事。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionListMergerTests: XCTestCase {

    private func session(
        _ id: String, title: String? = nil, updatedAt: Double, running: Bool = false,
        blank: Bool = false, origin: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            sessionId: id,
            updatedAt: updatedAt,
            running: running,
            blank: blank,
            agentAvailable: false,
            formatStatus: nil,
            parentSessionId: nil,
            origin: origin,
            cwd: nil,
            projections: title.map(Self.projections(title:))
        )
    }

    /// 一个只带标题的投影块 —— 标题就住在它的 `values` 里。
    private static func projections(title: String) -> SessionProjections {
        SessionProjections(kind: "cached", asOfSeq: 1, values: .object(["title": .string(title)]))
    }

    // MARK: - L1 事件不是基线

    /// 只喂变更、不给基线：一行的来源只有变更时它才出现 —— 这里断的是「合并**不**凭空
    /// 造出别的行」，而「拉取给基线」那一半在 `SessionListStateTests`。
    func testApplyingAChangeToNothingYieldsOnlyThatRow() {
        let rows = SessionListMerger.apply(.added(session("s1", updatedAt: 100)), to: [])
        XCTAssertEqual(rows.map(\.id), ["s1"])
    }

    // MARK: - L3 不重

    /// 同 id 再加一次：覆盖那一行，不长第二行。
    func testTheSameIdTwiceIsOneRow() {
        let first = SessionListMerger.apply(.added(session("s1", title: "旧", updatedAt: 100)), to: [])
        let second = SessionListMerger.apply(.added(session("s1", title: "新", updatedAt: 100)), to: first)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].title, "新")
    }

    /// 事件行没带投影块时，已有的那一格不该被抹掉 —— 标题就住在投影里。
    ///
    /// 上游每次 `agent/created` / `agent/disposed` 都重发一次 `added`，其中可能没有投影块；
    /// 若一律覆盖，一次这样的重发就把已知标题抹成「（无标题）」，直到下一次拉取。
    func testAnEventWithoutProjectionsKeepsTheKnownTitle() {
        let existing = [session("s1", title: "部署脚本", updatedAt: 100)]
        let rows = SessionListMerger.apply(.added(session("s1", updatedAt: 100)), to: existing)
        XCTAssertEqual(rows[0].title, "部署脚本", "没带投影 = 不知道标题，不是「没有标题」")
    }

    /// 带了投影就是新事实：标题跟着换。
    func testAnEventWithProjectionsReplacesTheTitle() {
        let existing = [session("s1", title: "旧", updatedAt: 100)]
        let rows = SessionListMerger.apply(.added(session("s1", title: "新", updatedAt: 100)), to: existing)
        XCTAssertEqual(rows[0].title, "新")
    }

    // MARK: - L4 顺序

    /// 活动时间变新即上浮到它该在的位置；时间不倒退。
    func testActivityMovesTheRowAndNeverRewindsTheClock() {
        let rows = [
            session("a", updatedAt: 300),
            session("b", updatedAt: 200),
            session("c", updatedAt: 100),
        ]
        let bumped = SessionListMerger.apply(.activity("c", updatedAt: 400), to: rows)
        XCTAssertEqual(bumped.map(\.id), ["c", "a", "b"], "最新活动在最前")
        XCTAssertEqual(bumped[0].updatedAt, 400)

        let stale = SessionListMerger.apply(.activity("b", updatedAt: 50), to: bumped)
        XCTAssertEqual(stale.map(\.id), ["c", "a", "b"], "更小的时间不该把它往下推")
        XCTAssertEqual(stale.map(\.updatedAt), [400, 300, 200], "也不该把时间写小")
    }

    /// 同一时间的两行：新来的排在**已有那一行之前还是之后**由插入点决定，
    /// 但绝不能因此把已有的那行挤掉。判据只断「两行都在、且新行在已存在的那行之前」——
    /// 因为「刚发生的」应当先被看见。
    func testATieGoesBeforeTheRowThatWasAlreadyThere() {
        let rows = [session("a", updatedAt: 100), session("b", updatedAt: 100)]
        let withNew = SessionListMerger.apply(.added(session("c", updatedAt: 100)), to: rows)
        XCTAssertEqual(withNew.map(\.id), ["c", "a", "b"])
    }

    /// 运行状态只改那一行、不动位置。
    func testStatusChangesOnlyTheFlag() {
        let rows = [session("a", updatedAt: 300), session("b", updatedAt: 200)]
        let changed = SessionListMerger.apply(.status("b", running: true), to: rows)
        XCTAssertEqual(changed.map(\.id), ["a", "b"], "运行状态不影响排序")
        XCTAssertEqual(changed.map(\.running), [false, true])

        let back = SessionListMerger.apply(.status("b", running: false), to: changed)
        XCTAssertEqual(back.map(\.running), [false, false], "跑完了也要能改回来")
    }

    /// 不认识的 id：状态与活动都不该往表里加一行。
    func testStatusAndActivityNeverCreateARow() {
        let rows = [session("a", updatedAt: 300)]
        XCTAssertEqual(SessionListMerger.apply(.status("ghost", running: true), to: rows).map(\.id), ["a"])
        XCTAssertEqual(SessionListMerger.apply(.activity("ghost", updatedAt: 900), to: rows).map(\.id), ["a"])
    }

    // MARK: - L5 删除

    /// 删了就没了；删一个不存在的 id 不出错。
    func testRemovalTakesTheRowAwayAndToleratesAnUnknownId() {
        let rows = [session("a", updatedAt: 300), session("b", updatedAt: 200)]
        XCTAssertEqual(SessionListMerger.apply(.removed("a"), to: rows).map(\.id), ["b"])
        XCTAssertEqual(SessionListMerger.apply(.removed("ghost"), to: rows).map(\.id), ["a", "b"])
    }

    /// 一条变更不带可见性判断：`blank` 的行照样进数组，画不画由**状态层**经
    /// `SessionVisibility` 决定 —— 合并层不复制那条规则（那一条在 `SessionListStateTests`）。
    func testVisibilityIsNotDecidedHere() {
        let rows = SessionListMerger.apply(.added(session("s1", updatedAt: 100, blank: true)), to: [])
        XCTAssertEqual(rows.map(\.id), ["s1"], "合并层不管可见性")
    }
}
