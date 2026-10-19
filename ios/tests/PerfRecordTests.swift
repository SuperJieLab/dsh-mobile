import XCTest
@testable import DshMobile

/// 性能记录出口 —— PerfRecord 的序列化形状（与网关 perf.ts 的
/// PerfRecord 同构）与 Log.perf 的门控、拼写。
final class PerfRecordTests: XCTestCase {

    private var lines: [String] = []
    private var previousDebug = false

    override func setUp() {
        super.setUp()
        lines = []
        previousDebug = Log.debugEnabled
        Log.perfSink = { [weak self] line in self?.lines.append(line) }
    }

    override func tearDown() {
        Log.perfSink = { line in FileHandle.standardError.write(Data(line.utf8)) }
        Log.debugEnabled = previousDebug
        super.tearDown()
    }

    func testSerializationCarriesSegTimestampSessionSeqAndFields() {
        let record = PerfRecord(
            seg: .dev,
            t: 1_758_000_000_000,
            sessionId: "s1",
            seq: 7,
            fields: ["devRecv": .number(1_758_000_000_100), "devApply": .number(1_758_000_000_125)]
        )
        let object = record.jsonObject()
        XCTAssertEqual(object["seg"] as? String, "dev")
        XCTAssertEqual(object["t"] as? Double, 1_758_000_000_000)
        XCTAssertEqual(object["sessionId"] as? String, "s1")
        XCTAssertEqual(object["seq"] as? Int, 7)
        XCTAssertEqual(object["devRecv"] as? Double, 1_758_000_000_100)
        XCTAssertEqual(object["devApply"] as? Double, 1_758_000_000_125)
    }

    func testAbsentOptionalFieldsStayOut() {
        let record = PerfRecord(seg: .res, t: 1, sessionId: nil, seq: nil, fields: [:])
        let object = record.jsonObject()
        XCTAssertNil(object["sessionId"], "缺的字段整个缺席，不填默认值")
        XCTAssertNil(object["seq"])
    }

    func testPerfLineSpellingAndGate() {
        let record = PerfRecord(
            seg: .dev,
            t: 1_758_000_000_000,
            sessionId: "s1",
            seq: 7,
            fields: ["devRecv": .number(1_758_000_000_100)]
        )
        Log.debugEnabled = false
        Log.perf(Log.Module.session, record)
        XCTAssertEqual(lines.count, 0, "门控关时零输出")

        Log.debugEnabled = true
        Log.perf(Log.Module.session, record)
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertTrue(line.contains("[dsh][perf][session]"), "与文本日志同一拼写")
        let json = String(line[line.range(of: "{")!.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["seg"] as? String, "dev")
        XCTAssertEqual(object?["seq"] as? Double, 7, "JSON 往返后按字段名读，不依赖键序")
    }
}
