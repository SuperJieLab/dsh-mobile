/**
 * 日志时间戳：形状、极性、毫秒补零，以及「写下的时刻就是那一刻」。
 *
 * 与网关侧同一组样本（`mac-gateway/tests/timestamp.test.ts`）—— 两份实现靠字面量对齐，
 * 不靠「记得同步」。两边都跑 `INSTANT` 那一组偏移，输出必须逐字相同。
 */
import Foundation
import XCTest

@testable import DshMobile

final class LogTimestampTests: XCTestCase {

    /// 与网关侧同一个时刻：2026-11-02T06:58:12.188Z。
    private let instant = Date(timeIntervalSince1970: 1_793_602_692.188)

    private func zone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier))
    }

    func testEastOfUTCKeepsTheWallClock() throws {
        XCTAssertEqual(LogTimestamp.string(from: instant, in: try zone("Asia/Shanghai")),
                       "2026-11-02T14:58:12.188+08:00")
    }

    func testWestOfUTCMinusFive() throws {
        XCTAssertEqual(LogTimestamp.string(from: instant, in: try zone("America/New_York")),
                       "2026-11-02T01:58:12.188-05:00",
                       "11 月 2 日纽约已过夏令时，是 -05:00 —— 偏移必须按那一刻问系统")
    }

    func testZeroOffsetIsWrittenZ() throws {
        XCTAssertEqual(LogTimestamp.string(from: instant, in: try zone("UTC")),
                       "2026-11-02T06:58:12.188Z")
    }

    func testANonWholeHourOffsetKeepsItsMinutes() throws {
        XCTAssertEqual(LogTimestamp.string(from: instant, in: try zone("Asia/Kolkata")),
                       "2026-11-02T12:28:12.188+05:30",
                       "把偏移当整数小时算，会在印度、尼泊尔这些地方静默错半小时")
    }

    func testMillisecondsAreAlwaysThreeDigits() throws {
        XCTAssertEqual(LogTimestamp.string(from: Date(timeIntervalSince1970: 1_793_602_692.005),
                                           in: try zone("UTC")),
                       "2026-11-02T06:58:12.005Z")
        XCTAssertEqual(LogTimestamp.string(from: Date(timeIntervalSince1970: 1_793_602_692.000),
                                           in: try zone("UTC")),
                       "2026-11-02T06:58:12.000Z")
    }

    /// 写下的那一串必须还能换算回同一刻 —— 否则那一行就是错的。
    func testTheWrittenStampDenotesTheSameInstant() throws {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for identifier in ["UTC", "Asia/Shanghai", "America/New_York", "Asia/Kolkata"] {
            let stamp = LogTimestamp.string(from: instant, in: try zone(identifier))
            let parsed = parser.date(from: stamp)
            XCTAssertEqual(parsed?.timeIntervalSince1970 ?? .nan, instant.timeIntervalSince1970,
                           accuracy: 0.001, "\(identifier) 写成 \(stamp)，换算回来对不上")
        }
    }

    func testTheShapeIsTheOneTheContractDocuments() throws {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})$"#
        for identifier in ["UTC", "Asia/Shanghai", "America/New_York"] {
            let stamp = LogTimestamp.string(from: instant, in: try zone(identifier))
            XCTAssertNotNil(stamp.range(of: pattern, options: .regularExpression),
                            "\(stamp) 不符合契约里写的那条形状")
        }
    }

    /// 默认时区取本机：生产调用点不传第二个参数。
    func testTheDefaultZoneIsThisDevice() {
        let stamp = LogTimestamp.string(from: instant)
        XCTAssertTrue(stamp.hasSuffix("Z") || stamp.range(of: #"[+-]\d{2}:\d{2}$"#,
                                                          options: .regularExpression) != nil,
                      "默认也必须带偏移 —— 不带偏移的本地时间有歧义")
    }
}
