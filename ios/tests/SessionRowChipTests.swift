/**
 * 列表行上那几枚标签的形状：谁在、什么字、什么顺序。
 *
 * 这一组是「标记」这件事唯一能被断言的地方 —— 视图不测，而「两枚能不能同现」
 * 「三条与一条怎么区分」正是最容易做错的两处。形状住在 `SessionRowChip`，
 * 视图只按返回值画。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionRowChipTests: XCTestCase {

    /// 没有待批、也没在跑 —— 一枚都不出，行里不留占位。
    func testNothingToSayYieldsNoChips() {
        XCTAssertEqual(SessionRowChip.of(running: false, pendingCount: 0), [])
        XCTAssertEqual(SessionRowChip.of(running: false, pendingCount: -1), [],
                       "负数是非法状态，同样不出标签，而不是画一个「待审批 -1」")
    }

    /// 只有运行态 —— 与只有这一枚标签时逐字相同。
    func testOnlyRunningYieldsTheRunningChip() {
        let chips = SessionRowChip.of(running: true, pendingCount: 0)
        XCTAssertEqual(chips, [.running])
        XCTAssertEqual(chips.map(\.text), ["进行中"])
    }

    /// 只有一条待批 —— 不带数字。单条是常态，「待审批 1」里的 1 没有信息量。
    func testASinglePendingChipCarriesNoNumber() {
        let chips = SessionRowChip.of(running: false, pendingCount: 1)
        XCTAssertEqual(chips, [.pending(count: 1)])
        XCTAssertEqual(chips.map(\.text), ["待审批"])
    }

    /// 两件事同时为真 —— 两枚并列、顺序固定；三条与一条在字面上可区分。
    func testRunningAndPendingCoexistInAFixedOrder() {
        let chips = SessionRowChip.of(running: true, pendingCount: 3)
        XCTAssertEqual(chips, [.running, .pending(count: 3)],
                       "先运行态后待批：顺序是形状的一部分，视图不再排")
        XCTAssertEqual(chips.map(\.text), ["进行中", "待审批 3"])
    }
}
