/**
 * 组网阶段投影的断言。投影与编排见同目录的 `MeshStore.swift` 与 `MeshPhase.swift`；
 * 对外阶段只由「节点状态 + 传输是否建成」两个输入决定。判定逻辑本身在 `TailnetNodeState`
 * （断言在 `tests/MeshNodeStateTests.swift`），这里只断言「投影无漏组合、编排时点不丢」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class MeshStoreTests: XCTestCase {

    /// 组网「刚就绪」的通知：只在**跨进** ready 那一次发。
    ///
    /// 两件事分别会坏，所以两头都断言：
    /// ① 每次回灌都发 ⇒ 每次路径刷新（direct↔relay 切换）都会叫连接重连一次，
    ///    而那条连接可能正好好的；
    /// ② 从不发 ⇒ 编排层收不到「组网好了」，连接永远停在等组网。
    func testPhaseReadyNotificationFiresOncePerTransition() async {
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        var readyCount = 0
        store.onPhaseReady = { readyCount += 1 }

        await store.start(config: config)
        XCTAssertEqual(readyCount, 0, "还没就绪就不该通知")

        // 隧道产物就位（`verifiedRoute` 的唯一写入点）→ 同时回灌一次。
        node.nodeState = .running
        node.onVerifiedRunning?(URLSession.shared)
        XCTAssertTrue(store.phase == .ready, "先确认真的就绪了，否则下面测的是别的分支")
        XCTAssertEqual(readyCount, 1, "跨进 ready 要通知一次")

        // 又一次回灌，阶段没变。
        node.onNodeChanged?()
        XCTAssertEqual(readyCount, 1, "保持 ready 时不该重复通知")

        // 掉下去再回来：中间那个非 ready 值必须被记下，否则回不来就不通知了。
        node.nodeState = .failed(.unreachable)
        node.onNodeChanged?()
        XCTAssertEqual(readyCount, 1, "掉下去本身不是「就绪」")
        node.nodeState = .running
        node.onNodeChanged?()
        XCTAssertEqual(readyCount, 2, "再回到 ready 是第二次跨进")
    }

    func testOrchestration() async {
        // —— 投影的全组合（2 节点态 × 2 组网；`failed` 两半各一次）——
        // 身份轴不并入组网阶段 —— 这件事现在由 `resolve` 的签名表达：签名里没有
        // 身份输入，就不存在「配对与否」这一维组合。
        for session in [true, false] {
            let noKey = MeshPhase.resolve(
                nodeState: .noKey, hasGatewaySession: session)
            XCTAssertTrue(noKey == .needsSetup, "N1a noKey（session=\(session)）")

            let registering = MeshPhase.resolve(
                nodeState: .registering, hasGatewaySession: session)
            XCTAssertTrue(registering == .connecting, "N1b registering（session=\(session)）")

            let badKey = MeshPhase.resolve(
                nodeState: .failed(.badKey), hasGatewaySession: session)
            XCTAssertTrue(badKey == .failed(.badKey), "N1e failed(badKey)（session=\(session)）")

            let unreachable = MeshPhase.resolve(
                nodeState: .failed(.unreachable), hasGatewaySession: session)
            XCTAssertTrue(unreachable == .failed(.unreachable),
                          "N1f failed(unreachable)（session=\(session)）")
        }
        // running 的两半：session 未建成的窄窗口 = connecting；建成 = ready
        let switching = MeshPhase.resolve(nodeState: .running, hasGatewaySession: false)
        XCTAssertTrue(switching == .connecting, "N1c running 但传输未切换 → connecting")
        let switched = MeshPhase.resolve(nodeState: .running, hasGatewaySession: true)
        XCTAssertTrue(switched == .ready, "N1d running 且传输已切换 → ready")

        // —— K4：启动零激活 + VerifiedRunning 唯一激活点——
        // 激活前 App 不持有隧道产物；产物从无到有只发生在节点验证 Running 那一刻。
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        await store.start(config: config)
        XCTAssertNil(store.route,
                     "K4a start 不激活：未激活 = 没有产物，不兜底")

        // 唯一激活点：节点验证 Running → 产物恰出现一次（隧道 session + 配置地址）。
        let tunnel = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(tunnel)
        XCTAssertTrue(store.route?.session === tunnel
                      && store.route?.baseURL == config.gatewayBaseURL!,
                      "K4b VerifiedRunning 唯一激活点：产物一次建成（不穿视图层）")
        XCTAssertTrue(store.phase == .ready, "K4c 激活后阶段投影为 ready")

        // —— N2d/N2e：start 进程内幂等（列表页 .task 重入触发
        // 第二次 start → 节点重启 → 活连接被杀 + 徽章掉直连标签）——
        await store.start(config: config)
        XCTAssertTrue(store.route?.session === tunnel,
                      "N2d start 幂等：重复 start 不重建产物（也不清空已建成的）")
        XCTAssertTrue(node.launchCount == 1,
                      "N2e start 幂等：重复 start 不再拉起节点（tsnet 重启会杀活连接）")

        // —— 回前台探活归属 store——
        node.reviveShouldFail = true
        await store.revive()
        XCTAssertTrue(store.phase == .failed(.unreachable),
                      "N3a 回前台探活失败 → 如实落 failed(unreachable)，不自动重试")
        // **产物跟着判据失效**：阶段不再是 ready 时，路就不通了 —— 这不是靠谁去清，
        // 是 `route` 在读数上守卫。删掉那道守卫，两条都会红。
        XCTAssertNil(store.route,
                     "N3a2 隧道不可用时 route 必须为 nil —— 否则上层还会往死地址打")
        node.nodeState = .running
        node.reviveShouldFail = false
        node.carrierPath = .direct
        await store.revive()
        XCTAssertTrue(store.phase == .ready && store.meshPath == .direct,
                      "N3b 探活可读 → 阶段保持 ready 且路径已刷新")

        // —— 推送通道：节点侧状态变化回灌 store，投影据此重算 ——
        // 视图已不观察节点的 @Published；轮询探到的失败 / 路径切换必须经
        // onNodeChanged 推到 store，否则投影冻结在最近一次 store 调用的快照上。
        node.nodeState = .failed(.unreachable)
        node.carrierPath = nil
        node.onNodeChanged?()
        XCTAssertTrue(store.phase == .failed(.unreachable) && store.meshPath == nil,
                      "N3c 节点侧状态变化经 onNodeChanged 回灌：store 投影随即跟随（不经显式 store 调用）")
    }

    /// 节点正在起时，第二次提交被明确拒绝，且**不改 `config`**。
    ///
    /// 两件事分开断言，因为症状不同：
    /// - 不拒 ⇒ 两条起节点的路并发，任一条的终局都会清掉另一条的产物；先失败的那条
    ///   还会把后成功的那条挡在 `.failed` 外面进不来（迁移表里没有那一格）。
    /// - 拒了但仍改了 `config` ⇒ 正在起的那条旧配置一旦成功，`onVerifiedRunning` 会用
    ///   **新**地址配**旧** session —— 「地址与传输同生共死」当场破掉。
    func testSubmittingWhileTheNodeIsStartingIsRefusedAndLeavesTheConfigAlone() async {
        let old = MeshConfig(controlURLString: "https://old.example:8443",
                             gatewayURLString: "http://100.64.0.1:3081")
        let new = MeshConfig(controlURLString: "https://new.example:8443",
                             gatewayURLString: "http://100.64.0.2:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        await store.start(config: old)

        node.isStarting = true
        XCTAssertTrue(store.isStarting, "「正在起」要透传给设置页做提交前的判断")

        let outcome = await store.submitMeshKey("hskey-auth-new", config: new)
        XCTAssertTrue(outcome == .refusedWhileNodeStarting, "起节点期间该明确拒绝，不能静默吞掉")
        XCTAssertEqual(node.submitCount, 0, "被拒的动作不该转交给节点层")
        let retryOutcome = await store.retryMesh(config: new)
        XCTAssertTrue(retryOutcome == .refusedWhileNodeStarting, "重试同样要拒 —— 它也会再起一条节点")

        // 旧配置那条最终还是成功了：产物必须配旧地址，而不是用户刚敲的新地址。
        node.isStarting = false
        node.nodeState = .running
        node.onVerifiedRunning?(URLSession(configuration: .ephemeral))
        XCTAssertEqual(store.route?.baseURL, old.gatewayBaseURL,
                       "被拒的配置不许进 config —— 否则旧 session 会配上新地址")
    }

    /// 回前台的重试用**存下来的那份**配置，不是调用方手里的。
    ///
    /// 为什么值得一条：`retryStored()` 一旦收参数，编排就有两种传法，而传「手里的那份」
    /// 正是「旧 session 配上新地址」那类缺陷的入口。接口上少一个参数，这条就不必再靠人记。
    func testRetryingFromForegroundUsesTheStoredConfig() async {
        let stored = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        await store.start(config: stored)

        await store.retryStored()

        XCTAssertEqual(node.retriedConfigs, [stored], "重试用的是 start 时存下的那份")
    }
}

// MARK: - 假件（只实现 store 的注入面，不 import TailscaleKit / 不碰网络）

@MainActor private final class FakeNode: MeshNodeControlling, @unchecked Sendable {
    var nodeState: TailnetNodeState = .noKey
    var carrierPath: CarrierPath?
    var isStarting = false
    var onVerifiedRunning: ((URLSession) -> Void)?
    var onNodeChanged: (() -> Void)?
    var reviveShouldFail = false
    var launchCount = 0
    var submitCount = 0
    var reviveCount = 0
    var retriedConfigs: [MeshConfig] = []
    func launchNode(config: MeshConfig) async {
        launchCount += 1
    }
    func reviveNode() async {
        reviveCount += 1
        if reviveShouldFail { nodeState = .failed(.unreachable) }
        // 真实节点在状态迁移与路径刷新处推送（TailnetNode.transition / refreshPathNow）；
        // 假件在事实变化点同样推送，回灌链路才被测到。
        onNodeChanged?()
    }
    func submitKey(_ key: String, config: MeshConfig) async -> MeshActionAcceptance {
        // 计「转交次数」而不是「接下次数」：后者会被本守卫吃掉，恒为 0，
        // 于是「被拒的动作不该转交给节点层」这条断言永远绿。
        submitCount += 1
        guard !isStarting else { return .refusedWhileNodeStarting }
        return .accepted
    }
    func retry(config: MeshConfig) async -> MeshActionAcceptance {
        retriedConfigs.append(config)
        guard !isStarting else { return .refusedWhileNodeStarting }
        return .accepted
    }
}
