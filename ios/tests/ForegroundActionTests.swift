/**
 * 回前台该动哪一步：只由组网阶段决定。
 *
 * 这条判定原来住在 `MeshStore.sceneActive()` 里，而它依据的一半输入（「App 回到前台」）
 * 组网域根本不认识。抽成纯函数之后，这里能穷举断言，装配那一跳只剩结构判据守。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ForegroundActionTests: XCTestCase {

    /// 上次判定为不可达 → 重走一次注册。
    ///
    /// 「用户回来了」是重新尝试最可靠的信号：比后台定时器省电，时机也更准（后台网络受限，
    /// 失败还会白白消耗次数）。探活对一条本来就不通的节点没有意义。
    func testPreviouslyUnreachableRetries() {
        XCTAssertEqual(ForegroundAction.of(phase: .failed(.unreachable)), .retryStored)
    }

    /// 其余每一档都只探活。
    ///
    /// 单独列出 `badKey` 而不是只测一个 `.ready`：key 被拒**不能**重试 —— 同样的 key 再问
    /// 一次答案不会变，而 authkey 有使用次数限制。这两档最容易写反（都是 `.failed`）。
    func testEveryOtherPhaseOnlyProbes() {
        let phases: [MeshPhase] = [.needsSetup, .connecting, .ready, .failed(.badKey)]
        for phase in phases {
            XCTAssertEqual(ForegroundAction.of(phase: phase), .revive,
                           "\(phase) 只该探活，不该重走注册")
        }
    }
}
