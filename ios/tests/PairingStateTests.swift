/**
 * 配对那一段的四条纪律 —— 它们在没有界面、没有网关、不起 `RpcClient` 的条件下跑。
 *
 * 这些纪律以前只写在注释里，因为 `PairingState` 的构造要一个 `RpcClient`（`final class`、
 * 没有协议），造不出来就断言不了。同类的 `MeshSetupState` 一直是闭包形状，有五条断言；
 * 配对这边一条都没有。
 *
 * 四条都对应**静默失败**：违反任何一条都不编译报错、也不会让别的断言变红。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class PairingStateTests: XCTestCase {

    // MARK: - 判定

    /// 满 6 位才可提交；5 位与 7 位都不行（服务端发的是 6 位）。
    func testCodeNeedsSixDigits() {
        let sut = make()
        for (code, expected) in [("12345", false), ("123456", true),
                                 ("1234567", false), ("", false)] {
            sut.code = code
            XCTAssertEqual(sut.canPair, expected, "「\(code)」的判定")
        }
    }

    /// 正在提交时不可再次提交 —— 否则连点会发两次。
    func testSubmittingBlocks() async {
        let gate = Gate()
        let sut = make(submit: { _ in await gate.hold() })
        sut.code = "123456"

        let inflight = Task { await sut.pair() }
        await gate.reached()
        XCTAssertTrue(sut.isPairing, "提交中")
        XCTAssertFalse(sut.canPair, "提交中不可再提交")
        gate.release()
        await inflight.value
        XCTAssertFalse(sut.isPairing, "提交结束后复位")
    }

    // MARK: - 四条纪律

    /// 失败**不清空**输入：改一位再试，不该整行重打。
    func testFailureKeepsTheCode() async {
        let sut = make(submit: { _ in throw TestError.rejected })
        sut.code = "123456"

        await sut.pair()

        XCTAssertEqual(sut.code, "123456", "失败之后输入要留着 —— 改一位就能再试")
        XCTAssertEqual(sut.failure, TestError.rejected.localizedDescription, "失败说原文")
    }

    /// 失败之后还能再点：`defer` 把 `isPairing` 复位。
    ///
    /// 挪掉 `defer` 的症状是「抛错后按钮永久灰着」，而它不会编译报错。
    func testFailureLeavesTheButtonUsable() async {
        let sut = make(submit: { _ in throw TestError.rejected })

        await sut.pair()
        XCTAssertFalse(sut.isPairing, "提交结束（失败也算结束）之后不该还在提交中")

        sut.code = "123456"
        XCTAssertTrue(sut.canPair, "失败之后可以再点")
    }

    /// 成功清空输入与上次失败。
    func testSuccessClearsCodeAndFailure() async {
        let sut = make(submit: { _ in throw TestError.rejected })
        sut.code = "111111"
        await sut.pair()
        XCTAssertNotNil(sut.failure, "先制造一次失败")

        let succeeding = make(submit: { _ in })
        succeeding.code = "123456"
        await succeeding.pair()

        XCTAssertEqual(succeeding.code, "", "成功之后输入清空")
        XCTAssertNil(succeeding.failure, "成功之后不残留上次的失败")
    }

    /// 提交动作**真被调用**，且拿到的是当前输入。
    ///
    /// 这条守的是最重的一处静默失败：把 `try await submit(code)` 删掉，配对会「成功」
    /// （`code` 照样清空、`failure` 照样为 nil），而凭证没有被写入 —— 界面停在配对页，
    /// 用户却什么提示都看不到。
    func testSubmitIsActuallyCalled() async {
        var submitted: [String] = []
        let sut = make(submit: { submitted.append($0) })
        sut.code = "123456"

        await sut.pair()

        XCTAssertEqual(submitted, ["123456"], "提交动作要真被调用，且拿到当前输入")
    }

    // MARK: - 解除

    /// 「有没有身份」跟着闭包走 —— 它读的是可观察对象，界面才会重算。
    func testUnlinkFollowsTheIdentity() async {
        var paired = false
        let sut = make(hasIdentity: { paired })
        XCTAssertFalse(sut.hasLinkedIdentity, "没身份时不显示解除")

        paired = true
        XCTAssertTrue(sut.hasLinkedIdentity, "身份翻真 → 解除出现")

        await sut.unlink()
    }

    /// 解除动作真被调用 —— 同 `testSubmitIsActuallyCalled` 的理由。
    func testUnlinkIsActuallyCalled() async {
        var unlinked = 0
        let sut = make(discardIdentity: { unlinked += 1 })

        await sut.unlink()

        XCTAssertEqual(unlinked, 1)
    }

    // MARK: - 假件

    private enum TestError: LocalizedError {
        case rejected
        var errorDescription: String? { "配对码不对" }
    }

    /// 卡住提交，用来观察「提交中」这一刻的状态。
    ///
    /// 两个 `CheckedContinuation` 各管一半：`reached` 让测试知道「已经进到 submit 里面」，
    /// `hold` 让 submit 停在原地直到测试放行。
    @MainActor
    private final class Gate {
        private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var didReach = false
        private var isReleased = false

        /// 提交动作里调它：报告「到了」，然后停住。
        func hold() async {
            didReach = true
            reachedWaiters.forEach { $0.resume() }
            reachedWaiters = []
            guard !isReleased else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        /// 测试调它：等到提交动作真的进去了。
        func reached() async {
            guard !didReach else { return }
            await withCheckedContinuation { reachedWaiters.append($0) }
        }

        /// 测试调它：放行。
        func release() {
            isReleased = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private func make(
        submit: @escaping (String) async throws -> Void = { _ in },
        hasIdentity: @escaping () -> Bool = { false },
        discardIdentity: @escaping () -> Void = {}
    ) -> PairingState {
        PairingState(submit: submit,
                     hasIdentity: hasIdentity,
                     discardIdentity: discardIdentity)
    }
}
