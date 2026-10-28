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

    /// 控制面必须是 https —— 明文控制面配不上证书。这条判在配置本身（`isComplete`），
    /// 组网段只把它与「密钥非空」与起来。
    func testControlPlaneMustBeHTTPS() {
        let sut = state()
        sut.tailnetKey = "hskey-auth-x"
        sut.controlURL = "http://example:8443"
        sut.gatewayURL = "http://100.64.0.1:3081"
        XCTAssertFalse(sut.canSubmit, "控制面是 http 时不该可提交")

        sut.controlURL = "https://example:8443"
        XCTAssertTrue(sut.canSubmit, "换成 https 后可提交")
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

    /// 盘上那份填进来时，两格与「重试要用的那份」一起换。
    ///
    /// 三样都要断言：只测其中一样时，漏填的那两处照样全绿 —— 而它们的症状不同
    /// （草稿空着会让人以为没配过，`stored` 没换则重试连的是旧地址）。
    func testAdoptingStoredFillsBothFieldsAndTheStoredCopy() {
        let sut = state()
        XCTAssertEqual(sut.controlURL, "", "起点是未配置的形状")

        let config = MeshConfig(controlURLString: "https://stored:8443",
                                gatewayURLString: "http://stored:3081")
        sut.adoptStored(config)

        XCTAssertEqual(sut.controlURL, "https://stored:8443", "控制面那格要填")
        XCTAssertEqual(sut.gatewayURL, "http://stored:3081", "网关那格要填")
        XCTAssertEqual(sut.stored, config, "重试要用的那份也是它")
    }

    /// 从盘上读：读得到就填，读坏了不填。
    ///
    /// 两个方向都测，因为「读坏了也填」和「读坏了不填」在正常盘上都表现为「填了」——
    /// 只有损坏态才分得开。而它的症状是误导：坏掉的配置被填进草稿，用户会以为
    /// 「我配过了，是网不通」，实际该做的是重填。
    func testAdoptingFromDiskFillsOnlyWhenItCanBeRead() {
        let suite = UserDefaults(suiteName: "mesh-setup-test-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }

        // ① 盘上什么都没有：草稿保持未配置的形状。
        let empty = state()
        empty.adoptStoredFromDisk(suite)
        XCTAssertEqual(empty.controlURL, "", "没配过就不该凭空长出一个地址")

        // ② 盘上是好的：填。
        let config = MeshConfig(controlURLString: "https://disk:8443",
                                gatewayURLString: "http://disk:3081")
        config.save(suite)
        let good = state()
        good.adoptStoredFromDisk(suite)
        XCTAssertEqual(good.controlURL, "https://disk:8443", "读得到就该填")
        XCTAssertEqual(good.stored, config, "重试要用的那份也跟着换")

        // ③ 盘上坏了：不填。
        let key = suite.dictionaryRepresentation().keys.first { $0.hasPrefix("mesh.") }
        XCTAssertNotNil(key, "先确认配置真的落盘了，否则这一支测的是空盘")
        suite.set("not json", forKey: key!)
        let damaged = state()
        damaged.adoptStoredFromDisk(suite)
        XCTAssertEqual(damaged.controlURL, "", "读坏了不该填 —— 那会让用户以为配过了")
        XCTAssertEqual(damaged.stored, MeshConfig(controlURLString: "", gatewayURLString: ""),
                       "坏配置也不能进「重试要用的那份」")
    }
}
