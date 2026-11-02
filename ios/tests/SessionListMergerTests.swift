/**
 * 会话列表的增量：一条变更怎么落到一串行上。
 *
 * 判据分两组：**解码**（线上载荷 → `SessionListChange`）与**合并**（变更 → 新的行序）。
 * 两组都只喂值、不碰网络与视图 —— 于是「顺序只有一条规则」这件事能在这里被钉住。
 *
 * 合并的另半边（在途期间记账、落地后重放）在 `SessionListStateTests`：那需要一条
 * 能被停住的取数，不是纯值类型的事。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionListMergerTests: XCTestCase {

    /// 一段 JSON 文本 → `JSONValue`（解码器的入口只收它）。
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func session(
        _ id: String, title: String? = nil, updatedAt: Double, running: Bool = false,
        createdAt: Double? = 1, blank: Bool = false, origin: String? = nil,
        workspaceId: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
            running: running, blank: blank, origin: origin, workspaceId: workspaceId
        )
    }

    // MARK: - L9 解码

    /// 四支各解一次；认不出的（别的 kind、空对象、缺字段）一律 nil。
    func testEveryChangeKindDecodesAndUnknownOnesDoNot() throws {
        let added = SessionListChange.decode(try json("""
        {"kind":"added","row":{"id":"s1","updatedAt":100,"running":true,"blank":false}}
        """))
        XCTAssertEqual(added, .added(SessionSummary(
            id: "s1", title: nil, createdAt: nil, updatedAt: 100,
            running: true, blank: false, origin: nil, workspaceId: nil
        )), "事件行没有 createdAt —— 它是可选的")

        XCTAssertEqual(SessionListChange.decode(try json(#"{"kind":"removed","id":"s1"}"#)),
                       .removed("s1"))
        XCTAssertEqual(
            SessionListChange.decode(try json(#"{"kind":"status","id":"s1","running":false}"#)),
            .status("s1", running: false))
        XCTAssertEqual(
            SessionListChange.decode(try json(#"{"kind":"activity","id":"s1","updatedAt":200}"#)),
            .activity("s1", updatedAt: 200))

        for text in [
            #"{"kind":"question","id":"s1"}"#,
            #"{"kind":"added"}"#,
            #"{"id":"s1"}"#,
            "{}",
            "null",
        ] {
            XCTAssertNil(SessionListChange.decode(try json(text)),
                         "「\(text)」不该解成变更")
        }
    }

    // MARK: - L1 事件不是基线

    /// 只喂变更、不给基线：一行的来源只有变更时它才出现 —— 这里断的是「合并**不**凭空
    /// 造出别的行」，而「拉取给基线」那一半在 `SessionListStateTests`。
    func testApplyingAChangeToNothingYieldsOnlyThatRow() {
        let rows = SessionListMerger.apply(.added(session("s1", updatedAt: 100, createdAt: nil)), to: [])
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

    /// 事件带来的行没有 `createdAt`：已有的那一格不该被它抹成 nil。
    func testAnEventNeverErasesTheCreationTimeOfAKnownRow() {
        let existing = [session("s1", updatedAt: 100, createdAt: 42)]
        let rows = SessionListMerger.apply(
            .added(session("s1", title: "标题", updatedAt: 100, createdAt: nil)), to: existing)
        XCTAssertEqual(rows[0].createdAt, 42, "事件不知道创建时间，不该把它清掉")
        XCTAssertEqual(rows[0].title, "标题", "它知道的那几格要更新")
    }

    /// 标题缺席时保留旧值 —— 与 `createdAt` 同一条规则。
    ///
    /// 上游每次 `agent/created` / `agent/disposed` 都重发一次 `added`，其中可能没有投影块；
    /// 若一律覆盖，一次这样的重发就把已知标题抹成「（无标题）」，直到下一次拉取。
    func testAnEventWithoutATitleKeepsTheKnownOne() {
        let existing = [session("s1", title: "部署脚本", updatedAt: 100)]
        let rows = SessionListMerger.apply(
            .added(session("s1", title: nil, updatedAt: 100, createdAt: nil)), to: existing)
        XCTAssertEqual(rows[0].title, "部署脚本")
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
        let withNew = SessionListMerger.apply(.added(session("c", updatedAt: 100, createdAt: nil)), to: rows)
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
        let rows = SessionListMerger.apply(
            .added(session("s1", updatedAt: 100, createdAt: nil, blank: true)), to: [])
        XCTAssertEqual(rows.map(\.id), ["s1"], "合并层不管可见性")
    }

    /// 归属这一格与 `title` 同一语义：事件行没带就保留旧值，带了就是新事实。
    ///
    /// 少了「没带就保留」，每收到一条不带归属的增量，那一行就会被赶进「未分组」——
    /// 而 `status` 与 `activity` 两类增根本来就不带它。
    func testAnAddedRowKeepsTheKnownWorkspaceUnlessItNamesAnother() {
        let known = session("s1", updatedAt: 100, workspaceId: "w-a")

        let silent = SessionListMerger.apply(.added(session("s1", updatedAt: 200)), to: [known])
        XCTAssertEqual(silent.first?.workspaceId, "w-a", "事件行没带归属时不得把已有归属抹掉")

        let moved = SessionListMerger.apply(
            .added(session("s1", updatedAt: 300, workspaceId: "w-b")), to: [known])
        XCTAssertEqual(moved.first?.workspaceId, "w-b", "带了归属就是新事实，覆盖旧值")
    }
}
