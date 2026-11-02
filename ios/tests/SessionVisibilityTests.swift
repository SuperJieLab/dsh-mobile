/**
 * 可见性规则的四条断言：`blank` 与 `subagent` 不显示；`origin` 缺省、以及其它取值都显示。
 *
 * 这四条是「哪些会话该出现在列表里」的唯一常驻判据 —— 规则住在
 * `SessionVisibility`，状态类型与视图都不再自己拼条件。
 *
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionVisibilityTests: XCTestCase {

    /// 一行摘要。只改与本规则有关的两个字段，其余给固定值。
    private func session(blank: Bool = false, origin: String? = nil) -> SessionSummary {
        SessionSummary(
            id: "s1",
            title: "会话",
            createdAt: 0,
            updatedAt: 0,
            running: false,
            blank: blank,
            origin: origin,
            workspaceId: nil
        )
    }

    func testBlankIsHidden() {
        XCTAssertFalse(SessionVisibility.isVisible(session(blank: true)), "尚未开始的候补会话不显示")
    }

    func testSubagentIsHidden() {
        XCTAssertFalse(SessionVisibility.isVisible(session(origin: "subagent")), "子会话不显示")
    }

    func testMissingOriginIsShown() {
        XCTAssertTrue(SessionVisibility.isVisible(session(origin: nil)), "没有 origin 的普通会话显示")
    }

    /// 只拦 `subagent` 这一个取值，不是「非空就拦」。
    func testOtherOriginIsShown() {
        XCTAssertTrue(SessionVisibility.isVisible(session(origin: "elsewhere")), "其它 origin 照常显示")
    }
}
