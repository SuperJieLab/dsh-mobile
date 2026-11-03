import XCTest
@testable import DshMobile

/// 遥测落盘的判据。这一层的错法都不会立刻显形：文件写坏了要等真出事那天才发现，
/// 保留策略写反了要等磁盘被填满。
final class TelemetryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func store(retention: Int = 20) -> TelemetryStore {
        TelemetryStore(directory: directory, retention: retention)
    }

    /// 存下去的是**原字节**。中间转一手（解析再序列化）会把系统给的字段悄悄改掉，
    /// 而这份文件存在的理由就是「原样留着」。
    func testSavedBytesSurviveUnchanged() throws {
        let payload = Data(#"{"launch":{"p50":123.5},"crash":0}"#.utf8)
        let url = try store().save(payload, kind: .metrics, at: Date())

        XCTAssertEqual(try Data(contentsOf: url), payload, "落盘的内容必须与交来的字节一致")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("metrics-"), "文件名要能认出类别")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".json"))
    }

    /// 超出保留份数时删**最旧的**，不是最新的。
    ///
    /// 反了的话，留下的是三周前的数据，而你要看的是昨天那次崩溃 —— 这个错误在文件数
    /// 没超过上限时完全看不出来。
    func testRetentionDropsTheOldest() throws {
        let store = store(retention: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for offset in 0..<5 {
            let when = base.addingTimeInterval(TimeInterval(offset * 60))
            try store.save(Data("payload-\(offset)".utf8), kind: .metrics, at: when)
        }

        let kept = store.files(.metrics)
        XCTAssertEqual(kept.count, 3, "只留 retention 份")

        // 新的在前：第 4、3、2 份（offset 4/3/2）该在，0 与 1 该被删。
        let contents = kept.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(contents, ["payload-4", "payload-3", "payload-2"], "留下的必须是最新的那几份")
    }

    /// 两类各留各的：诊断稀疏而指标每天一份，共用一个上限会让诊断被指标挤掉。
    func testTheTwoKindsDoNotCompeteForRoom() throws {
        let store = store(retention: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try store.save(Data("m0".utf8), kind: .metrics, at: base)
        try store.save(Data("d0".utf8), kind: .diagnostics, at: base.addingTimeInterval(1))
        try store.save(Data("m1".utf8), kind: .metrics, at: base.addingTimeInterval(2))
        try store.save(Data("m2".utf8), kind: .metrics, at: base.addingTimeInterval(3))

        XCTAssertEqual(store.files(.metrics).count, 2, "指标留 2 份")
        XCTAssertEqual(store.files(.diagnostics).count, 1, "诊断不该被指标挤掉")
    }

    /// `files` 只回这一类。前缀判断写宽了（比如只看后缀）会把另一类也带出来，
    /// 而调用方会拿指标去当诊断读。
    func testFilesFiltersByKind() throws {
        let store = store()
        try store.save(Data("m".utf8), kind: .metrics, at: Date())
        try store.save(Data("d".utf8), kind: .diagnostics, at: Date())

        XCTAssertEqual(store.files(.metrics).count, 1)
        XCTAssertEqual(store.files(.diagnostics).count, 1)
        XCTAssertTrue(store.files(.metrics)[0].lastPathComponent.hasPrefix("metrics-"))
    }

    /// 目录还不存在时也要能存 —— 首次运行就是这种情况。
    func testSavingCreatesTheDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "前置：目录本来不存在")
        try store().save(Data("x".utf8), kind: .metrics, at: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - 订阅者的注册

    /// `start()` 重复调用只注册一次。启动编排原则上只跑一次，但「原则上」不是判据 ——
    /// 重复注册会让同一份 payload 落两遍，而那是磁盘慢慢被填满的那种错。
    func testStartingTwiceRegistersOnce() {
        var registrations = 0
        let reporter = MetricKitReporter(store: store()) { _ in registrations += 1 }

        reporter.start()
        reporter.start()
        reporter.start()

        XCTAssertEqual(registrations, 1, "注册必须幂等")
    }
}
