/**
 * 派生行与标题的两源合并（`SessionRows.make`）。
 *
 * 标题有两个来源：行自带的 `projections.values.title`（冷会话只有它有），与
 * `session/control` 推来的 `title` 投影（活会话改名后靠它）。判据钉住三件事：
 * 推来的优先、缺席时退回行自带的那一格、两边都没有就是 `nil`（不是空串）。
 *
 * 合成只在一处发生 —— 状态、视图、分组都读它的结果，所以「列表与详情标题不一致」
 * 这类问题只能在这里出现或消失。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionRowTests: XCTestCase {

    private func summary(_ id: String,
                         projectionTitle: String? = nil,
                         running: Bool = false,
                         origin: String? = nil,
                         updatedAt: Double = 100) -> SessionSummary {
        SessionSummary(
            sessionId: id, updatedAt: updatedAt, running: running, blank: false,
            agentAvailable: false, formatStatus: nil, parentSessionId: nil,
            origin: origin, cwd: nil,
            projections: projectionTitle.map {
                SessionProjections(kind: "cached", asOfSeq: 1, values: .object(["title": .string($0)]))
            }
        )
    }

    /// 投影推来的标题覆盖行自带的那个。
    func testThePushedTitleWinsOverTheRowProjection() {
        let rows = SessionRows.make([summary("s1", projectionTitle: "旧名")],
                                    titles: ["s1": "新名"])

        XCTAssertEqual(rows.map(\.title), ["新名"])
    }

    /// 没有推来的标题时退回行自带的那一格 —— 控制流还没建好时列表仍然有标题。
    func testWithoutAPushedTitleTheRowProjectionIsUsed() {
        let rows = SessionRows.make([summary("s1", projectionTitle: "行里的名")], titles: [:])

        XCTAssertEqual(rows.map(\.title), ["行里的名"])
    }

    /// 两边都没有就是 `nil`（界面给「无标题」），不是空串 —— 空串会画出一个空行。
    func testNoTitleAnywhereIsNil() {
        let rows = SessionRows.make([summary("s1")], titles: [:])

        XCTAssertNil(rows[0].title)
    }

    /// 其它字段照抄线上那一行：派生只改标题，不改事实。
    func testEveryOtherFieldIsCarriedThrough() {
        let rows = SessionRows.make(
            [summary("s1", running: true, origin: "subagent", updatedAt: 42)],
            titles: ["s1": "名"]
        )

        XCTAssertEqual(rows[0].id, "s1")
        XCTAssertTrue(rows[0].running)
        XCTAssertFalse(rows[0].blank)
        XCTAssertEqual(rows[0].origin, "subagent")
        XCTAssertEqual(rows[0].updatedAt, 42)
    }

    /// 顺序不动：服务端已按最近发言排好，派生行不该顺手再排一遍。
    func testTheIncomingOrderIsKept() {
        let rows = SessionRows.make(
            [summary("a", updatedAt: 200), summary("b", updatedAt: 100)],
            titles: [:]
        )

        XCTAssertEqual(rows.map(\.id), ["a", "b"])
    }
}
