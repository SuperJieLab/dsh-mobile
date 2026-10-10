/**
 * 连接域投影断言（R3 N1–N3）。投影与编排见
 * Sources/Core/Connection/ConnectionStore.swift；对外阶段的唯一源 = Plan R3 §3.3
 * 决定 1 与 §3.1 链路图。判定逻辑本身在 TailnetNodeState（run-mesh.sh 断言对象），
 * 这里只断言「投影无漏组合、编排时点不丢」。
 */
import Foundation

@MainActor
@main
struct ConnectionStoreTests {

    private static func run() async {
        // —— N1：全组合投影（5 节点态 × 2 身份 × 2 承载）——
        // noKey 与节点态无关 → needsSetup（含 isPaired 的组合：身份轴不并入连接阶段，决定 5）
        for paired in [true, false] {
            for hasSession in [true, false] {
                expect(ConnectionPhase.resolve(nodeState: .noKey, isPaired: paired, hasGatewaySession: hasSession) == .needsSetup,
                       "N1a noKey（paired=\(paired) session=\(hasSession)）→ needsSetup")
            }
        }
        // registering → connecting（session 不可能建成，但组合仍断言，防漏）
        for paired in [true, false] {
            for hasSession in [true, false] {
                expect(ConnectionPhase.resolve(nodeState: .registering, isPaired: paired, hasGatewaySession: hasSession) == .connecting,
                       "N1b registering（paired=\(paired) session=\(hasSession)）→ connecting")
            }
        }
        // running 的两半：session 未建成的窄窗口 = connecting；建成 = ready
        for paired in [true, false] {
            expect(ConnectionPhase.resolve(nodeState: .running, isPaired: paired, hasGatewaySession: false) == .connecting,
                   "N1c running 但承载未切换（paired=\(paired)）→ connecting")
            expect(ConnectionPhase.resolve(nodeState: .running, isPaired: paired, hasGatewaySession: true) == .ready,
                   "N1d running 且承载已切换（paired=\(paired)）→ ready")
        }
        // failed 原因可区分（badKey ≠ unreachable）
        for paired in [true, false] {
            for hasSession in [true, false] {
                expect(ConnectionPhase.resolve(nodeState: .failed(.badKey), isPaired: paired, hasGatewaySession: hasSession) == .failed(.badKey),
                       "N1e failed(badKey)（paired=\(paired) session=\(hasSession)）→ failed(badKey)")
                expect(ConnectionPhase.resolve(nodeState: .failed(.unreachable), isPaired: paired, hasGatewaySession: hasSession) == .failed(.unreachable),
                       "N1f failed(unreachable)（paired=\(paired) session=\(hasSession)）→ failed(unreachable)")
            }
        }

        // —— N2：兜底激活 + VerifiedRunning 激活内化（决定 2、6）——
        // 兜底：start() 即以 .shared session 激活 MeshConfig 里的网关地址（配对不等组网）
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let client = FakeClient()
        let store = ConnectionStore(client: client, node: node)
        await store.start(config: config)
        expect(client.activations.count == 1
               && client.activations[0].1 == config.gatewayBaseURL!
               && client.activations[0].0 === URLSession.shared,
               "N2a start() 兜底激活：立即用 .shared 激活配置地址（配对不等组网 Running）")

        // 内化：节点验证 Running → 回调消费方是 store，client 恰再收到一次
        // 「节点产出的 session + 配置地址」的激活，阶段随即 .ready
        let tunnel = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(tunnel)
        expect(client.activations.count == 2
               && client.activations[1].0 === tunnel
               && client.activations[1].1 == config.gatewayBaseURL!,
               "N2b VerifiedRunning 回调内化：client 收到隧道承载激活（不穿视图层）")
        expect(store.phase == .ready, "N2c 激活后阶段投影为 ready")

        // —— N3：回前台探活归属 store（决定 6）——
        node.reviveShouldFail = true
        await store.sceneActive()
        expect(store.phase == .failed(.unreachable),
               "N3a 回前台探活失败 → 如实落 failed(unreachable)，不自动重试")
        node.nodeState = .running
        node.reviveShouldFail = false
        node.carrierPath = .direct
        await store.sceneActive()
        expect(store.phase == .ready && store.meshPath == .direct,
               "N3b 探活可读 → 阶段保持 ready 且路径已刷新")

        print("")
        print("passed=\(passed) failed=\(failed)")
        if failed > 0 { exit(1) }
    }

    static func main() async { await run() }
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
    var reviveShouldFail = false
    func launchNode(config: MeshConfig) async {}
    func reviveNode() async {
        if reviveShouldFail { nodeState = .failed(.unreachable) }
    }
}
