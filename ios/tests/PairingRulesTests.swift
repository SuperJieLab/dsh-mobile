/**
 * 配对屏两条提交规则的断言 —— 它们在没有界面、没有网关、不构造状态对象的条件下跑。
 *
 * 出处：`R18-3` 的 E1 / E2（纯规则必须有断言、同一屏的同类规则住同一种地方）。基准是
 * `SessionVisibility` 的四条：规则住一个纯类型，断言只喂入参。
 *
 * 这一屏原先有两种住法并存：「配对码能不能提交」是 `PairingState` 上的属性（零断言），
 * 「组网能不能提交」是视图 `disabled` 表达式里当场拼的（零断言）。现在两条都在
 * `PairingRules` 里，各自的输入仍归原主。
 *
 * 最后一条是结构检查（规则没有第二份）：两处调用方都只许出现规则调用，不许把判据抄回来。
 *
 * 跑法：`xcodebuild test -only-testing:DshMobileTests/PairingRulesTests`。
 */
import Foundation
import XCTest

@testable import DshMobile

final class PairingRulesTests: XCTestCase {

    // MARK: - 配对码

    /// 满 6 位才可提交；5 位与 7 位都不行（服务端发的是 6 位）。
    func testCodeNeedsSixDigits() {
        XCTAssertFalse(PairingRules.canSubmitCode("12345", isSubmitting: false), "5 位不可提交")
        XCTAssertTrue(PairingRules.canSubmitCode("123456", isSubmitting: false), "6 位可提交")
        XCTAssertFalse(PairingRules.canSubmitCode("1234567", isSubmitting: false), "7 位不可提交")
        XCTAssertFalse(PairingRules.canSubmitCode("", isSubmitting: false), "空串不可提交")
    }

    /// 正在提交时不可再次提交 —— 否则连点会发两次。
    func testSubmittingBlocks() {
        XCTAssertFalse(PairingRules.canSubmitCode("123456", isSubmitting: true),
                       "提交中不可再提交")
        XCTAssertFalse(PairingRules.canSubmitCode("", isSubmitting: true),
                       "提交中 + 输入不足，仍不可提交")
    }

    // MARK: - 组网录入

    /// 密钥非空 + 配置完整，才可提交。三个输入各缺一次，都要判不可提交。
    func testMeshSubmit() {
        let complete = MeshConfig(controlURLString: "https://10.0.0.1:8443",
                                  gatewayURLString: "http://100.64.0.1:3081")

        XCTAssertFalse(PairingRules.canSubmitMesh(key: "", config: complete), "密钥为空不可提交")
        XCTAssertTrue(PairingRules.canSubmitMesh(key: "hskey-auth-x", config: complete),
                      "密钥非空 + 配置完整可提交")

        let httpControl = MeshConfig(controlURLString: "http://10.0.0.1:8443",
                                     gatewayURLString: "http://100.64.0.1:3081")
        XCTAssertFalse(PairingRules.canSubmitMesh(key: "hskey-auth-x", config: httpControl),
                       "控制面必须是 https（明文控制面配不上证书）")

        let noGateway = MeshConfig(controlURLString: "https://10.0.0.1:8443",
                                   gatewayURLString: "")
        XCTAssertFalse(PairingRules.canSubmitMesh(key: "hskey-auth-x", config: noGateway),
                       "网关地址为空不可提交")
    }

    /// 「配置是否完整」这条规则本身：控制面要 `https`，网关地址只需是个 URL。
    func testMeshConfigCompleteness() {
        XCTAssertTrue(MeshConfig(controlURLString: "https://a:8443",
                                 gatewayURLString: "http://b:3081").isComplete)
        XCTAssertFalse(MeshConfig(controlURLString: "http://a:8443",
                                  gatewayURLString: "http://b:3081").isComplete,
                       "明文控制面不算完整")
        XCTAssertFalse(MeshConfig(controlURLString: "",
                                  gatewayURLString: "http://b:3081").isComplete,
                       "还没配过（控制面为空）不算完整")
        XCTAssertFalse(MeshConfig(controlURLString: "https://a:8443",
                                  gatewayURLString: "").isComplete,
                       "网关地址为空不算完整")
    }

    // MARK: - 规则没有第二份

    /// 两个调用方都不许把判据抄回来：`PairingState` 与 `PairingView` 的代码行里不再出现
    /// `count == 6` / `key.isEmpty` 这类规则碎片。
    ///
    /// 只扫这两个文件的代码行（注释行跳过）：注释里引用判据是讲解，不是第二份实现。
    /// 盲区：换个写法的等价判据（`code.count >= 6`）认不出 —— 漏报方向，靠评审。
    func testRuleHasNoSecondCopy() throws {
        let state = sourcesRoot.appendingPathComponent("Features/Pairing/State/PairingState.swift")
        let view = sourcesRoot.appendingPathComponent("Features/Pairing/Views/PairingView.swift")
        let fragments = ["count == 6", "count >= 6", "key.isEmpty", "tailnetKey.isEmpty"]

        var scanned = 0
        for file in [state, view] {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("PairingRules"), "\(file.lastPathComponent) 没在读规则")
            for (line, code) in codeLines(in: text) {
                scanned += 1
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for fragment in fragments where code.contains(fragment) {
                    XCTFail("\(file.lastPathComponent):\(line) 出现「\(fragment)」"
                            + " —— 判据只许住 PairingRules（E2）")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 0, "两个文件一行都没扫到 —— 先怀疑路径推算")
    }

    // MARK: - 路径与扫描

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ios/tests/
            .deletingLastPathComponent()   // ios/
            .appendingPathComponent("Sources")
    }

    private func codeLines(in text: String) -> [(Int, String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }
}
