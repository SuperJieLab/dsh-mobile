/**
 * TailnetNodeState 迁移表逐格断言。状态与事件定义见
 * Sources/Core/MeshNetwork/TailnetNodeState.swift；迁移表以该文件里的 `switch` 为唯一源
 * 与状态图都以它为准 —— 加一个状态时编译器会点出所有要看它的地方。
 */
import Foundation
import XCTest

@testable import DshMobile

final class MeshNodeStateTests: XCTestCase {

    func testTransitions() {
        // —— 启动（读沙盒 key + 上次节点持久状态 + 那状态属于哪家控制面）——
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: false, nodeStateHealthy: false,
                                                      controlPlaneMatches: true)) == .noKey,
                      "MS1 无 key 启动 → noKey")
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: false, nodeStateHealthy: true,
                                                      controlPlaneMatches: true)) == .noKey,
                      "MS2 有残留节点状态但无 key → noKey（key 是唯一准入事实）")
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: true, nodeStateHealthy: true,
                                                      controlPlaneMatches: true)) == .running,
                      "MS3 有 key 且节点持久状态完好 → running（重开不重注册）")
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: true, nodeStateHealthy: false,
                                                      controlPlaneMatches: true)) == .registering,
                      "MS4 有 key 但节点状态不在/损坏过 → registering")
        // 换了控制面：目录完好也不算数 —— 里面那份身份是上一家的，拿它连新控制面
        // 会「连上但通不了」。这一格是 C52 的判据本体：把 controlPlaneMatches 从判定里
        // 拿掉，它就从 registering 变 running（旧行为）。
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: true, nodeStateHealthy: true,
                                                      controlPlaneMatches: false)) == .registering,
                      "MS4′ 有 key、目录完好、但控制面换了 → registering（旧身份对新控制面无效）")
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: true, nodeStateHealthy: false,
                                                      controlPlaneMatches: false)) == .registering,
                      "MS4″ 控制面换了且目录坏了 → registering（两条原因指向同一个补救）")
        // 无 key 时控制面是否一致不参与判定：本来就要重新注册。
        XCTAssertTrue(TailnetNodeState.handle(.launch(keyPresent: false, nodeStateHealthy: true,
                                                      controlPlaneMatches: false)) == .noKey,
                      "MS4‴ 无 key 且控制面换了 → noKey（key 仍然优先）")

        // —— noKey → 注册 ——
        XCTAssertTrue(TailnetNodeState.handle(.keySubmitted, from: .noKey) == .registering,
                      "MS5 noKey 输入接入 key → registering")
        XCTAssertTrue(TailnetNodeState.handle(.keySubmitted, from: .failed(.unreachable)) == .registering,
                      "MS6 failed 后重输 key 同样走 registering（统一入口）")

        // —— 注册结果 ——
        XCTAssertTrue(TailnetNodeState.handle(.registrationSucceeded, from: .registering) == .running,
                      "MS7 注册成功 → running")
        XCTAssertTrue(TailnetNodeState.handle(.registrationFailed(.badKey), from: .registering) == .failed(.badKey),
                      "MS8 key 无效/过期 → failed(badKey)")
        XCTAssertTrue(TailnetNodeState.handle(.registrationFailed(.unreachable), from: .registering) == .failed(.unreachable),
                      "MS9 控制面不可达 → failed(unreachable)")
        XCTAssertTrue(TailnetNodeState.handle(.registrationFailed(.badKey), from: .running) == .failed(.badKey),
                      "MS10 running 中续期失败也落 failed（重入网失败可区分）")

        // —— failed 修复重试 ——
        XCTAssertTrue(TailnetNodeState.handle(.retry(keyPresent: true), from: .failed(.badKey)) == .registering,
                      "MS11 failed 换 key 后重试 → registering")
        XCTAssertTrue(TailnetNodeState.handle(.retry(keyPresent: false), from: .failed(.unreachable)) == .noKey,
                      "MS12 failed 且 key 已不在 → noKey（fail-closed）")

        // —— running 的稳态 ——
        XCTAssertTrue(TailnetNodeState.handle(.appBackgrounded, from: .running) == .running,
                      "进后台不迁移：挂起停摆由 tsnet 复活 + 回前台重连接力，不进状态机")
        XCTAssertTrue(TailnetNodeState.handle(.nodeUnreachable, from: .running) == .failed(.unreachable),
                      "MS14 running 中节点失联 → failed(unreachable)（如实显示，不自动重试风暴）")
        XCTAssertTrue(TailnetNodeState.handle(.registrationSucceeded, from: .running) == .running,
                      "MS15 前台复活再次报注册成功 → 仍 running（幂等）")

        // —— 被新一代取代（改配置打断在跑的接入）——
        // 只断言「期望值与兜底不同」的那两格。`.registering` 与 `.noKey` 遇 `superseded` 的
        // 结果与「该格不写、落进 default 返回原状态」逐字相同，任何断言都恒真 —— 实测：把整段
        // 迁移改成 `return state`，那两条仍绿。所以它们不写断言，源码里也不单列。
        XCTAssertTrue(TailnetNodeState.handle(.superseded, from: .running) == .registering,
                      "MS16 running 被取代 → registering：旧一代的产物作废，状态必须离开 running（否则 route 仍指向已关闭的节点）")
        XCTAssertTrue(TailnetNodeState.handle(.superseded, from: .failed(.badKey)) == .registering,
                      "MS17 failed(badKey) 被取代 → registering")
        XCTAssertTrue(TailnetNodeState.handle(.superseded, from: .failed(.unreachable)) == .registering,
                      "MS18 failed(unreachable) 被取代 → registering（两个失败原因都要被这条 pattern 覆盖）")
    }
}
