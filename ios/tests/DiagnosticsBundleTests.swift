import XCTest
@testable import DshMobile

/// 诊断包组装的判据。它是纯函数，所以「包里到底有什么」可以逐字看见。
final class DiagnosticsBundleTests: XCTestCase {

    private func input(log: String = "line-1\nline-2\n",
                       telemetry: [(name: String, text: String)] = []) -> DiagnosticsBundle.Input {
        DiagnosticsBundle.Input(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.1.0",
            appBuild: "276",
            system: "Version 26.5 (Build 23F77)",
            device: "iPhone17,1",
            logTail: log,
            telemetry: telemetry
        )
    }

    /// 头部四行是「这份包是谁的」—— 少了它们，一个包离开设备之后就无法归因。
    func testHeaderCarriesVersionSystemAndDevice() {
        let text = DiagnosticsBundle.text(input())
        XCTAssertTrue(text.contains("App：0.1.0 (276)"))
        XCTAssertTrue(text.contains("系统：Version 26.5"))
        XCTAssertTrue(text.contains("设备：iPhone17,1"))
    }

    /// 日志原样进包（脱敏之后）。少一行就等于少一个线索。
    func testLogLinesAreCarried() {
        let text = DiagnosticsBundle.text(input(log: "alpha\nbeta\n"))
        XCTAssertTrue(text.contains("alpha"))
        XCTAssertTrue(text.contains("beta"))
    }

    /// 没有遥测时写一句明确的「还没有」，而不是留一片空白 ——
    /// 空白让人以为是导出坏了。
    func testEmptyTelemetryIsSaidOutLoud() {
        let text = DiagnosticsBundle.text(input(telemetry: []))
        XCTAssertTrue(text.contains("还没有收到过 payload"))
    }

    /// 遥测按文件名分节。
    func testTelemetryIsLabelledByName() {
        let text = DiagnosticsBundle.text(input(
            telemetry: [(name: "metrics-1700000000000.json", text: #"{"launch":1}"#)]
        ))
        XCTAssertTrue(text.contains("=== 遥测：metrics-1700000000000.json ==="))
        XCTAssertTrue(text.contains(#"{"launch":1}"#))
    }

    // MARK: - 脱敏

    /// **导出包里不含凭据**。这一条不能靠调用点自觉 —— 那保证不了任何事，
    /// 所以脱敏是组装时的一道工序。
    func testBearerTokensAreRedacted() {
        let secret = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let text = DiagnosticsBundle.text(input(log: "auth: \(secret)\n"))

        XCTAssertFalse(text.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), "凭证不得出现在包里")
        XCTAssertTrue(text.contains("Bearer <redacted>"))
    }

    /// `token=<长随机串>` 这种形态同样要换掉 —— 它是另一条常见的打印方式。
    func testKeyValueCredentialsAreRedacted() {
        let text = DiagnosticsBundle.text(input(log: "deviceToken=abc123def456ghi789jkl\n"))
        XCTAssertFalse(text.contains("abc123def456ghi789jkl"))
        XCTAssertTrue(text.contains("deviceToken=<redacted>"))
    }

    /// **不误伤**：短值与非凭证语境里的词原样留着。
    ///
    /// 脱敏过度会让诊断包失去价值 —— 一份读不懂的日志不比没有好。
    /// 这条判据和上面两条是一对：只测「该换的换了」，把实现改成「见 token 就删」
    /// 也能全绿，而那种实现会把正常日志一起毁掉。
    func testOrdinaryWordsSurvive() {
        let line = "token and ticket cleared; key=abc; Bearer is required"
        let text = DiagnosticsBundle.text(input(log: line + "\n"))
        XCTAssertTrue(text.contains("token and ticket cleared"), "普通词不该被换掉")
        XCTAssertTrue(text.contains("key=abc"), "短值不是凭证")
        XCTAssertTrue(text.contains("Bearer is required"), "没有凭证时这句原样留着")
    }
}
