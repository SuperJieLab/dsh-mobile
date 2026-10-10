/**
 * 连接域投影断言（R3 N1–N3）。投影与编排见
 * Sources/Core/Connection/ConnectionStore.swift；对外阶段的唯一源 = Plan R3 §3.3
 * 决定 1 与 §3.1 链路图。判定逻辑本身在 TailnetNodeState（run-mesh.sh 断言对象），
 * 这里只断言「投影无漏组合、编排时点不丢」。
 */
import Foundation

@main
struct ConnectionStoreTests {

    private static func run() {
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

        print("")
        print("passed=\(passed) failed=\(failed)")
        if failed > 0 { exit(1) }
    }

    static func main() { run() }
}
