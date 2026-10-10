/**
 * TailnetNodeState 迁移表逐格断言（M8 O1）。状态与事件定义见
 * Sources/Core/MeshNetwork/TailnetNodeState.swift；迁移表以 Plan M8 §3.2 决定 6
 * 与 §3.3 状态图为唯一源。
 */
import Foundation

@main
struct MeshNodeStateTests {

    private static func run() {
    // —— 启动（读 Keychain + 上次节点持久状态）——
    expect(TailnetNodeState.handle(.launch(keyPresent: false, nodeStateHealthy: false)) == .noKey,
           "MS1 无 key 启动 → noKey")
    expect(TailnetNodeState.handle(.launch(keyPresent: false, nodeStateHealthy: true)) == .noKey,
           "MS2 有残留节点状态但无 key → noKey（key 是唯一准入事实）")
    expect(TailnetNodeState.handle(.launch(keyPresent: true, nodeStateHealthy: true)) == .running,
           "MS3 有 key 且节点持久状态完好 → running（重开不重注册）")
    expect(TailnetNodeState.handle(.launch(keyPresent: true, nodeStateHealthy: false)) == .registering,
           "MS4 有 key 但节点状态不在/损坏过 → registering")

    // —— noKey → 注册 ——
    expect(TailnetNodeState.handle(.keySubmitted, from: .noKey) == .registering,
           "MS5 noKey 输入接入 key → registering")
    expect(TailnetNodeState.handle(.keySubmitted, from: .failed(.unreachable)) == .registering,
           "MS6 failed 后重输 key 同样走 registering（统一入口）")

    // —— 注册结果 ——
    expect(TailnetNodeState.handle(.registrationSucceeded, from: .registering) == .running,
           "MS7 注册成功 → running")
    expect(TailnetNodeState.handle(.registrationFailed(.badKey), from: .registering) == .failed(.badKey),
           "MS8 key 无效/过期 → failed(badKey)")
    expect(TailnetNodeState.handle(.registrationFailed(.unreachable), from: .registering) == .failed(.unreachable),
           "MS9 控制面不可达 → failed(unreachable)")
    expect(TailnetNodeState.handle(.registrationFailed(.badKey), from: .running) == .failed(.badKey),
           "MS10 running 中续期失败也落 failed（重入网失败可区分）")

    // —— failed 修复重试 ——
    expect(TailnetNodeState.handle(.retry(keyPresent: true), from: .failed(.badKey)) == .registering,
           "MS11 failed 换 key 后重试 → registering")
    expect(TailnetNodeState.handle(.retry(keyPresent: false), from: .failed(.unreachable)) == .noKey,
           "MS12 failed 且 key 已不在 → noKey（fail-closed）")

    // —— running 的稳态 ——
    expect(TailnetNodeState.handle(.appBackgrounded, from: .running) == .running,
           "MS13 进后台不迁移：挂起停摆由 tsnet 复活 + M3 重连接力，不进状态机")
    expect(TailnetNodeState.handle(.nodeUnreachable, from: .running) == .failed(.unreachable),
           "MS14 running 中节点失联 → failed(unreachable)（如实显示，不自动重试风暴）")
    expect(TailnetNodeState.handle(.registrationSucceeded, from: .running) == .running,
           "MS15 前台复活再次报注册成功 → 仍 running（幂等）")

    // —— 状态目录损坏：任何状态都回 noKey ——
    for from in [TailnetNodeState.noKey, .registering, .running, .failed(.badKey), .failed(.unreachable)] {
        expect(TailnetNodeState.handle(.stateStoreCorrupted, from: from) == .noKey,
               "MS16 \(from) 遇状态目录损坏 → noKey（fail-closed，与 M4 凭证损坏同口径）")
    }

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }

    static func main() { run() }
}
