/**
 * 恢复时该动哪一步：只由组网阶段决定。
 *
 * 判定住 `MeshPhase` —— 它本来就知道每一档的来由，「key 被拒不重试」正是阶段语义的一部分。
 * 装配那一跳只剩结构判据守。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class MeshPhaseTests: XCTestCase {

    /// 上次判定为不可达 → 重走一次注册。
    ///
    /// 「用户回来了」是重新尝试最可靠的信号：比后台定时器省电，时机也更准（后台网络受限，
    /// 失败还会白白消耗次数）。探活对一条本来就不通的节点没有意义。
    func testPreviouslyUnreachableRetries() {
        XCTAssertTrue(MeshPhase.failed(.unreachable).shouldRetryRegistration)
    }

    /// 其余每一档都只探活。
    ///
    /// 单独列出 `badKey` 而不是只测一个 `.ready`：key 被拒**不能**重试 —— 同样的 key 再问
    /// 一次答案不会变，而 authkey 有使用次数限制。这两档最容易写反（都是 `.failed`）。
    func testEveryOtherPhaseOnlyProbes() {
        let phases: [MeshPhase] = [.needsSetup, .connecting, .ready, .failed(.badKey)]
        for phase in phases {
            XCTAssertFalse(phase.shouldRetryRegistration,
                           "\(phase) 只该探活，不该重走注册")
        }
    }
}
