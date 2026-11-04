import XCTest
@testable import DshMobile

/// 日志落盘的判据。
///
/// 这一层最要紧的一条是**被杀之后仍读得到**：`LogFile` 的每个实例都从文件重建状态，
/// 所以「新建一个实例读同一个文件」就是重启的最小替身 —— 它不依赖真的杀掉进程。
final class LogFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logfile-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func url() -> URL { directory.appendingPathComponent("current.log") }

    /// 模拟「上一次跑写下这些行，进程被杀，这次重开」。
    ///
    /// 这一条不红就说明落盘没生效 —— 而那正是这个组件存在的全部理由。
    func testLinesSurviveANewInstance() throws {
        let first = LogFile(url: url())
        first.append("line-1\n")
        first.append("line-2\n")

        // 新实例 = 重启。它不该持有上一份的内存状态。
        let second = LogFile(url: url())
        XCTAssertEqual(second.tail(), "line-1\nline-2\n", "上一次跑的尾巴必须读得到")
    }

    /// 超过上限时保留**后半**，不是清空。
    ///
    /// 清空之后「上一次跑发生了什么」只剩一句「文件刚被清」—— 那等于没留。
    func testRotationKeepsTheTailNotTheHead() throws {
        let file = LogFile(url: url(), maxBytes: 200)

        // 每行 20 字节左右，写 40 行远超上限。
        for index in 0..<40 {
            file.append("line-\(String(format: "%03d", index))-padding\n")
        }

        let tail = file.tail()
        XCTAssertTrue(tail.contains("line-039"), "最新的那行必须在")
        XCTAssertFalse(tail.contains("line-000"), "最旧的那行该被轮转掉")
    }

    /// `tail` 超限时从**行首**开始 —— 半行日志读起来是噪音，还会让第一行看起来像损坏。
    func testTailStartsAtALineBoundary() throws {
        let file = LogFile(url: url())
        for index in 0..<50 {
            file.append("line-\(index)\n")
        }

        let tail = file.tail(maxBytes: 40)
        XCTAssertFalse(tail.hasPrefix("ine-"), "不该从一行中间切开：\(tail)")
        XCTAssertTrue(tail.hasSuffix("\n"))
    }

    /// 文件还不存在时 `tail` 回空串而不是崩 —— 首次运行就是这种情况。
    func testTailOnAMissingFileIsEmpty() {
        XCTAssertEqual(LogFile(url: url()).tail(), "")
    }

    /// **`Log` 真的接到文件上了**。
    ///
    /// 上面几条只证明 `LogFile` 自己能用；这一条证明那个唯一出口真的把行交给了它。
    /// 少了它，`writeRaw` 里少一行 `fileSink?(line)` 也能让上面全绿 ——
    /// 而那意味着整个落盘从来没生效过。
    func testInstallingRoutesTheLogIntoTheFile() throws {
        let file = LogFile(url: url())
        Log.installFileLog(file)
        defer { Log.installFileLog(nil) }

        Log.info(Log.Module.session, "probe-line-from-test")

        XCTAssertTrue(file.tail().contains("probe-line-from-test"),
                      "日志出口没把行交给文件 —— 落盘等于没装")
    }

    /// 卸掉之后不再写文件（判据之间不互相污染）。
    func testUninstallingStopsWriting() {
        let file = LogFile(url: url())
        Log.installFileLog(file)
        Log.installFileLog(nil)

        Log.info(Log.Module.session, "after-uninstall")

        XCTAssertFalse(file.tail().contains("after-uninstall"))
    }

    // MARK: - 字段的拼法

    /// 按 key 排序。顺序不固定的话，「这行变了没」每次都要重新看 —— 而日志最常做的
    /// 比对就是「上一次和这一次哪里不一样」。
    func testFieldsAreSortedByKey() {
        let text = Log.formatFields(["z": "1", "a": "2", "m": "3"])
        XCTAssertEqual(text, " a=2 m=3 z=1")
    }

    /// 空字典什么都不加 —— 不留一个尾随空格。少了这条，每条无字段的日志都会多一个
    /// 看不见的尾巴，而 `grep " $"` 会突然命中一片。
    func testEmptyFieldsAddNothing() {
        XCTAssertEqual(Log.formatFields([:]), "")
    }

    /// 含空格的值要加引号，否则 `msg=a b` 读起来像两个字段。
    func testValuesWithSpacesAreQuoted() {
        XCTAssertEqual(Log.formatFields(["msg": "a b"]), #" msg="a b""#)
        XCTAssertEqual(Log.formatFields(["msg": "plain"]), " msg=plain")
    }
}
