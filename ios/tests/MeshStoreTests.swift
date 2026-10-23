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
        // 激活前 App 不持有端点；端点从无到有只发生在节点验证 Running 那一刻。
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let client = FakeClient()
        let store = MeshStore(client: client, node: node)
        await store.start(config: config)
        XCTAssertTrue(client.activations.isEmpty,
                      "K4a start 不激活：未激活 = 端点不存在，不兜底")

        // 唯一激活点：节点验证 Running → client 恰收到一次「隧道 session + 配置地址」。
        let tunnel = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(tunnel)
        XCTAssertTrue(client.activations.count == 1
                      && client.activations[0].0 === tunnel
                      && client.activations[0].1 == config.gatewayBaseURL!,
                      "K4b VerifiedRunning 唯一激活点：端点一次建成（不穿视图层）")
        XCTAssertTrue(store.phase == .ready, "K4c 激活后阶段投影为 ready")

        // —— N2d/N2e：start 进程内幂等（列表页 .task 重入触发
        // 第二次 start → 节点重启 → 活连接被杀 + 徽章掉直连标签）——
        let activationsBefore = client.activations.count
        await store.start(config: config)
        XCTAssertTrue(client.activations.count == activationsBefore,
                      "N2d start 幂等：重复 start 不重复兜底激活（传输切换只此一次）")
        XCTAssertTrue(node.launchCount == 1,
                      "N2e start 幂等：重复 start 不再拉起节点（tsnet 重启会杀活连接）")

        // —— 回前台探活归属 store——
        node.reviveShouldFail = true
        await store.sceneActive()
        XCTAssertTrue(store.phase == .failed(.unreachable),
                      "N3a 回前台探活失败 → 如实落 failed(unreachable)，不自动重试")
        node.nodeState = .running
        node.reviveShouldFail = false
        node.carrierPath = .direct
        await store.sceneActive()
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
}

// MARK: - 假件（只实现 store 的注入面，不 import TailscaleKit / 不碰网络）

private final class FakeClient: GatewayActivating, @unchecked Sendable {
    /// (session, baseURL) 记录对，按激活顺序排列。
    var activations: [(URLSession, URL)] = []
    func activate(session: URLSession, baseURL: URL) {
        activations.append((session, baseURL))
    }
}

@MainActor private final class FakeNode: MeshNodeControlling, @unchecked Sendable {
    var nodeState: TailnetNodeState = .noKey
    var carrierPath: CarrierPath?
    var onVerifiedRunning: ((URLSession) -> Void)?
    var onNodeChanged: (() -> Void)?
    var reviveShouldFail = false
    var launchCount = 0
    func launchNode(config: MeshConfig) async {
        launchCount += 1
    }
    func reviveNode() async {
        if reviveShouldFail { nodeState = .failed(.unreachable) }
        // 真实节点在状态迁移与路径刷新处推送（TailnetNode.transition / refreshPathNow）；
        // 假件在事实变化点同样推送，回灌链路才被测到。
        onNodeChanged?()
    }
    func submitKey(_ key: String, config: MeshConfig) async {}
    func retry(config: MeshConfig) async {}
}
