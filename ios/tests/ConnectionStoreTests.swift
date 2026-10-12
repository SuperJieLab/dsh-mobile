/**
 * 连接域投影断言（R3 N1–N3）。投影与编排见
 * Sources/Core/Connection/ConnectionStore.swift；对外阶段的唯一源 = Plan R3 §3.3
 * 决定 1 与 §3.1 链路图。判定逻辑本身在 TailnetNodeState（断言在 tests/MeshNodeStateTests.swift），
 * 这里只断言「投影无漏组合、编排时点不丢」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ConnectionStoreTests: XCTestCase {

    func testOrchestration() async {
        // —— N1：全组合投影（5 节点态 × 2 身份 × 2 承载）——
        // noKey 与节点态无关 → needsSetup（含 isPaired 的组合：身份轴不并入连接阶段，决定 5）
        for paired in [true, false] {
            for hasSession in [true, false] {
                XCTAssertTrue(ConnectionPhase.resolve(nodeState: .noKey, isPaired: paired, hasGatewaySession: hasSession) == .needsSetup,
                              "N1a noKey（paired=\(paired) session=\(hasSession)）→ needsSetup")
            }
        }
        // registering → connecting（session 不可能建成，但组合仍断言，防漏）
        for paired in [true, false] {
            for hasSession in [true, false] {
                XCTAssertTrue(ConnectionPhase.resolve(nodeState: .registering, isPaired: paired, hasGatewaySession: hasSession) == .connecting,
                              "N1b registering（paired=\(paired) session=\(hasSession)）→ connecting")
            }
        }
        // running 的两半：session 未建成的窄窗口 = connecting；建成 = ready
        for paired in [true, false] {
            XCTAssertTrue(ConnectionPhase.resolve(nodeState: .running, isPaired: paired, hasGatewaySession: false) == .connecting,
                          "N1c running 但承载未切换（paired=\(paired)）→ connecting")
            XCTAssertTrue(ConnectionPhase.resolve(nodeState: .running, isPaired: paired, hasGatewaySession: true) == .ready,
                          "N1d running 且承载已切换（paired=\(paired)）→ ready")
        }
        // failed 原因可区分（badKey ≠ unreachable）
        for paired in [true, false] {
            for hasSession in [true, false] {
                XCTAssertTrue(ConnectionPhase.resolve(nodeState: .failed(.badKey), isPaired: paired, hasGatewaySession: hasSession) == .failed(.badKey),
                              "N1e failed(badKey)（paired=\(paired) session=\(hasSession)）→ failed(badKey)")
                XCTAssertTrue(ConnectionPhase.resolve(nodeState: .failed(.unreachable), isPaired: paired, hasGatewaySession: hasSession) == .failed(.unreachable),
                              "N1f failed(unreachable)（paired=\(paired) session=\(hasSession)）→ failed(unreachable)")
            }
        }

        // —— K4：启动零激活 + VerifiedRunning 唯一激活点（R5 决定 2）——
        // 激活前 App 不持有端点；端点从无到有只发生在节点验证 Running 那一刻。
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let client = FakeClient()
        let store = ConnectionStore(client: client, node: node)
        await store.start(config: config)
        XCTAssertTrue(client.activations.isEmpty,
                      "K4a start 不激活：未激活 = 端点不存在，不兜底（R5 删 LAN 兜底）")

        // 唯一激活点：节点验证 Running → client 恰收到一次「隧道 session + 配置地址」。
        let tunnel = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(tunnel)
        XCTAssertTrue(client.activations.count == 1
                      && client.activations[0].0 === tunnel
                      && client.activations[0].1 == config.gatewayBaseURL!,
                      "K4b VerifiedRunning 唯一激活点：端点一次建成（不穿视图层）")
        XCTAssertTrue(store.phase == .ready, "K4c 激活后阶段投影为 ready")

        // —— N2d/N2e：start 进程内幂等（真机 2026-10-10：列表页 .task 重入触发
        // 第二次 start → 节点重启 → 活连接被杀 + 徽章掉直连标签）——
        let activationsBefore = client.activations.count
        await store.start(config: config)
        XCTAssertTrue(client.activations.count == activationsBefore,
                      "N2d start 幂等：重复 start 不重复兜底激活（承载切换只此一次）")
        XCTAssertTrue(node.launchCount == 1,
                      "N2e start 幂等：重复 start 不再拉起节点（tsnet 重启会杀活连接）")

        // —— N3：回前台探活归属 store（决定 6）——
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

        // —— 推送通道：节点侧状态变化回灌 store（收口审查 C1 的关闭判据）——
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
    var isPaired = true
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
