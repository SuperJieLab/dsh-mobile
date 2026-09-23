/**
 * 审批对账的重建测试（Q1–Q6）。
 *
 * 与 `SessionMirrorTests` / `UsageStateTests` 同一手法：状态机不碰网络、不碰 UI，
 * 这里只喂事件序列与对账名单，看建出几张卡。
 *
 * 判据与出处：docs/dev/plans/M5-remote-intervention.md §3.3 表 + 实施期修正 14。
 *
 * 事实来源（`approval/asked` − `approval/decided`）本身不足以判定「还挂着」——
 * 真机上抓到两条 `asked` 没有 `decided`，它们的同一 turn 里 `turn/end` 已经落下、
 * 紧随的 `tool/result` 写着 `TOOL_OUTCOME_UNKNOWN`：进程在等 outcome 的中途被杀，
 * `decided` 没来得及落。上游保证 `approval.request()` 在 turn 内阻塞到 outcome
 * 落盘，所以 **turn 闭合而 decided 缺席 = 残骸**，不是待批。
 */
import Foundation

@main
struct ApprovalReconcileTests {

    private static var passed = 0
    private static var failed = 0

    private static func expect(_ ok: Bool, _ label: String) {
        if ok {
            passed += 1
            print("ok   \(label)")
        } else {
            failed += 1
            print("FAIL \(label)")
        }
    }

    private static func ev(_ seq: Int, _ type: String, _ data: [String: JSONValue] = [:]) -> SessionEvent {
        SessionEvent(type: type, seq: seq, time: 1_789_000_000_000, data: .object(data))
    }

    private static func asked(_ seq: Int, id: String, callId: String? = nil) -> SessionEvent {
        var data: [String: JSONValue] = ["id": .string(id), "toolName": .string("bash")]
        if let callId { data["callId"] = .string(callId) }
        return ev(seq, "approval/asked", data)
    }

    private static func decided(_ seq: Int, id: String) -> SessionEvent {
        ev(seq, "approval/decided", ["id": .string(id), "outcome": .string("rejected")])
    }

    /// 真机抓到的残骸形态（原样：`approval/asked` 后紧跟带错的 `tool/result`，
    /// 再 `step/end` → `turn/end`，中间没有任何 `approval/decided`）。
    private static func wreck(_ base: Int, id: String, callId: String) -> [SessionEvent] {
        [
            ev(base, "assistant/message"),
            ev(base + 1, "tool/call", ["name": .string("bash")]),
            asked(base + 2, id: id, callId: callId),
            ev(base + 3, "tool/result", ["error": .object(["code": .string("TOOL_OUTCOME_UNKNOWN")])]),
            ev(base + 4, "step/end"),
            ev(base + 5, "turn/end"),
        ]
    }

    private static func sync(_ eventIds: [String], callIds: [String], stale: Bool = false) -> JSONValue {
        .object([
            "kind": .string("sync"),
            "eventIds": .array(eventIds.map { .string($0) }),
            "callIds": .array(callIds.map { .string($0) }),
            "stale": .bool(stale),
        ])
    }

    static func main() {
        MainActor.assumeIsolated {
            let client = GatewayClient(baseURL: URL(string: "http://127.0.0.1:9")!)

            // Q1：崩溃残骸不建卡 —— 会话日志里 asked 没有 decided，但 turn 已闭合。
            let wrecked = ApprovalStore(client: client)
            wrecked.rebuild(from: wreck(244, id: "b2dd61b1", callId: "call_00_ET_FiVdc"))
            expect(wrecked.pending.isEmpty, "Q1 turn 已闭合的 asked（残骸）不建卡")

            // Q2：turn 未闭合的 asked 照常建卡 —— 那才是真的还挂着，不许误杀。
            let live = ApprovalStore(client: client)
            live.rebuild(from: [
                ev(283, "assistant/message"),
                ev(284, "tool/call", ["name": .string("bash")]),
                asked(285, id: "c186c564", callId: "call_00_ET_Baq0u"),
            ])
            expect(
                live.pending.count == 1 && live.pending.first?.id == "c186c564",
                "Q2 turn 未闭合的 asked 照常建卡"
            )

            // Q3：正常收口（asked + decided）不建卡 —— 既有行为，回归保护。
            let settled = ApprovalStore(client: client)
            settled.rebuild(from: [
                asked(284, id: "c186c564", callId: "call_00_ET_Baq0u"),
                decided(285, id: "c186c564"),
            ])
            expect(settled.pending.isEmpty, "Q3 asked 后 decided 收口，不建卡")

            // Q4：残骸与活审批共存 —— 只留活的那张（同一次重建里两种判定都要对）。
            let mixed = ApprovalStore(client: client)
            mixed.rebuild(from:
                wreck(244, id: "b2dd61b1", callId: "call_00_ET_FiVdc")
                + [
                    ev(290, "assistant/message"),
                    asked(291, id: "cdf80c37", callId: "call_00_ET_Qnb7p"),
                ]
            )
            expect(
                mixed.pending.count == 1 && mixed.pending.first?.id == "cdf80c37",
                "Q4 残骸与活审批共存时只留活的"
            )

            // Q5：窗口从 turn 中间截断（没有 turn/end）→ 保守建卡，宁可多问不可漏。
            let truncated = ApprovalStore(client: client)
            truncated.rebuild(from: [
                asked(247, id: "b2dd61b1", callId: "call_00_ET_FiVdc"),
                ev(248, "tool/result"),
            ])
            expect(truncated.pending.count == 1, "Q5 窗口截断（无 turn/end）时保守建卡")

            // Q6：权威名单到达 → 对账结论在同一次调用里生效，不必等下一次刷新。
            let reconciled = ApprovalStore(client: client)
            reconciled.rebuild(from: [asked(247, id: "b2dd61b1", callId: "call_00_ET_FiVdc")])
            expect(reconciled.pending.count == 1, "Q6a 收到名单前，未闭合的 asked 先建卡")
            reconciled.receive(sync([], callIds: []))
            expect(reconciled.pending.isEmpty, "Q6b 权威名单到达后，对账立即生效")

            // Q7：stale 名单不清卡 —— relay 未就绪时名单证明不了任何事。
            let stale = ApprovalStore(client: client)
            stale.rebuild(from: [asked(247, id: "b2dd61b1", callId: "call_00_ET_FiVdc")])
            stale.receive(sync([], callIds: [], stale: true))
            expect(stale.pending.count == 1, "Q7 stale 名单不清卡")

            print("—— \(passed) passed, \(failed) failed ——")
            if failed > 0 { exit(1) }
        }
    }
}
