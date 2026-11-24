/**
 * 取分子规则。
 *
 * 规则从网关的 `upstream/usage.ts` 搬来，搬的是一次**行为迁移** —— 没有这条判据，
 * 「搬完之后取法变了」不会有任何信号（两边都编译、都不崩，只是数字不同）。
 */
import XCTest
@testable import DshMobile

final class UsageViewTests: XCTestCase {

    private func values(_ pressure: [String: JSONValue], breakdown: [String: JSONValue]? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["contextPressure": .object(pressure)]
        if let breakdown { object["contextBreakdown"] = .object(breakdown) }
        return .object(object)
    }

    /// `projectedTokens` 优先：两格都在时不许退回采样值。
    func testProjectedTokensWinsOverPressureTokens() {
        let reading = UsageView.snapshotOf(
            values(["contextWindow": .number(128_000), "pressureTokens": .number(32_000), "projectedTokens": .number(34_000)]),
            asOfSeq: 7
        )
        XCTAssertEqual(reading.usage?.usedTokens, 34_000)
        XCTAssertEqual(reading.usage?.contextWindow, 128_000)
        XCTAssertEqual(reading.asOfSeq, 7)
    }

    /// 缺 `projectedTokens` 才退回 `pressureTokens`。
    func testFallsBackToPressureTokens() {
        let reading = UsageView.snapshotOf(
            values(["contextWindow": .number(128_000), "pressureTokens": .number(32_000)]),
            asOfSeq: 1
        )
        XCTAssertEqual(reading.usage?.usedTokens, 32_000)
    }

    /// 分子或分母缺一即「未知」，不是 0%。
    func testMissingHalfMeansUnknown() {
        XCTAssertNil(UsageView.snapshotOf(values(["contextWindow": .number(128_000)]), asOfSeq: 1).usage)
        XCTAssertNil(UsageView.snapshotOf(values(["projectedTokens": .number(34_000)]), asOfSeq: 1).usage)
        XCTAssertNil(UsageView.snapshotOf(values(["contextWindow": .number(0), "projectedTokens": .number(1)]), asOfSeq: 1).usage,
                     "零容量不可作除数")
    }

    /// 拆解三项齐备才出；全零等同于缺省（未动过的会话没有可展开之物）。
    func testBreakdownNeedsAllThreeAndIsNotEmpty() {
        let full = UsageView.snapshotOf(
            values(["contextWindow": .number(100), "projectedTokens": .number(50)],
                   breakdown: ["systemTokens": .number(1), "toolsTokens": .number(2), "messageTokens": .number(3)]),
            asOfSeq: 1
        )
        XCTAssertEqual(full.usage?.breakdown, UsageBreakdown(systemTokens: 1, toolsTokens: 2, messageTokens: 3))

        let partial = UsageView.snapshotOf(
            values(["contextWindow": .number(100), "projectedTokens": .number(50)],
                   breakdown: ["systemTokens": .number(1)]),
            asOfSeq: 1
        )
        XCTAssertNil(partial.usage?.breakdown, "残缺的拆解误导多于告知")

        let zero = UsageView.snapshotOf(
            values(["contextWindow": .number(100), "projectedTokens": .number(50)],
                   breakdown: ["systemTokens": .number(0), "toolsTokens": .number(0), "messageTokens": .number(0)]),
            asOfSeq: 1
        )
        XCTAssertNil(zero.usage?.breakdown)
    }
}
