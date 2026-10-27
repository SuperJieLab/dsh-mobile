/**
 * 组网录入那一段的三条不变式 —— 都对着一段具体的坑，不是覆盖率。
 *
 * 三条都由「替身收下什么」来判：保存与提交各是一个闭包，于是「存的是不是交出去的那份」
 * 可以直接比对，不必去读 UserDefaults（读了也说不清是不是这一次写的）。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class MeshSetupStateTests: XCTestCase {

    private func state(
        stored: MeshConfig = MeshConfig(controlURLString: "", gatewayURLString: ""),
        saved: @escaping (MeshConfig) -> Void = { _ in },
        submitted: @escaping (String, MeshConfig) -> Void = { _, _ in },
        retried: @escaping (MeshConfig) -> Void = { _ in }
    ) -> MeshSetupState {
        MeshSetupState(stored: stored,
                       save: saved,
                       submit: { key, config in submitted(key, config) },
                       retry: { config in retried(config) })
    }

    /// 落盘的那一份与交给连接域的那一份必须是同一份。
    ///
    /// 写成两次构造（一次 save、一次 load 再交出去）时，两份会在「存成功、读失败」这类
    /// 时刻分叉 —— 而界面显示的是草稿，谁也不会怀疑连的是另一份。
    func testSavedAndSubmittedAreTheSameConfig() async {
        var saved: [MeshConfig] = []
        var submitted: [MeshConfig] = []
        let sut = state(saved: { saved.append($0) }, submitted: { _, config in submitted.append(config) })

        sut.controlURL = "https://example:8443"
        sut.gatewayURL = "http://100.64.0.1:3081"
        sut.tailnetKey = "hskey-auth-x"
        await sut.saveAndConnect()

        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(saved.first, submitted.first, "存的和连的必须是同一份配置")
    }

    /// 密钥先捕获再清空 —— 提交是异步的，顺序反了提交的永远是空串。
    func testKeyIsHandedOverBeforeTheFieldIsCleared() async {
        var keys: [String] = []
        let sut = state(submitted: { key, _ in keys.append(key) })

        sut.controlURL = "https://example:8443"
        sut.gatewayURL = "http://100.64.0.1:3081"
        sut.tailnetKey = "hskey-auth-x"
        await sut.saveAndConnect()

        XCTAssertEqual(keys, ["hskey-auth-x"])
        XCTAssertEqual(sut.tailnetKey, "", "提交之后输入框该空")
    }

    /// 重试用**存下来的**那份，不是草稿：用户改了地址却没保存，重试不该偷偷按新的连。
    func testRetryUsesTheStoredConfigNotTheDraft() async {
        let stored = MeshConfig(controlURLString: "https://stored:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        var retried: [MeshConfig] = []
        let sut = state(stored: stored, retried: { retried.append($0) })

        sut.controlURL = "https://draft:8443"
        await sut.retryMesh()

        XCTAssertEqual(retried, [stored])
    }

    /// 能不能提交跟着规则走：没有密钥不行，两格地址不成形也不行。
    func testCanSubmitFollowsTheRule() {
        let sut = state()
        XCTAssertFalse(sut.canSubmit, "空输入不该可提交")

        sut.tailnetKey = "hskey-auth-x"
        XCTAssertFalse(sut.canSubmit, "地址不成形也不该可提交")

        sut.controlURL = "https://example:8443"
        sut.gatewayURL = "http://100.64.0.1:3081"
        XCTAssertTrue(sut.canSubmit)
    }
}
