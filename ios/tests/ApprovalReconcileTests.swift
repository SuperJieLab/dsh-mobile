/**
 * 待批审批重建的七条断言（Q1–Q7）：判定不碰网络、不碰界面，喂事件序列与对账名单，看建出几张卡。
 *
 * 判据与出处：M5 §3.3 表 + 实施期修正 14；R16 期2 把判定从 `ApprovalStore` 移到 `ApprovalInbox`
 * 之后，这里**不再构造任何客户端** —— 这一条本身就是「待批集合不依赖客户端」的证据（判据 L10）。
 *
 * 事实来源（`approval/asked` − `approval/decided`）不足以判定「还挂着」：真机上两条
 * `asked` 无 `decided`，其同一 turn 里 `turn/end` 已落、紧随的 `tool/result` 写着
 * `TOOL_OUTCOME_UNKNOWN` —— 进程在等 outcome 的中途被杀。上游 `approval.request()` 在
 * turn 内阻塞到 outcome 落盘，故 **turn 闭合而 decided 缺席 = 残骸**，不是待批。
 */
import Foundation
import XCTest

@testable import DshMobile

final class ApprovalReconcileTests: XCTestCase {

    private func ev(_ seq: Int, _ type: String, _ data: [String: JSONValue] = [:]) -> SessionEvent {
        SessionEvent(type: type, seq: seq, time: 1_789_000_000_000, data: .object(data))
    }

    private func asked(_ seq: Int, id: String, callId: String? = nil) -> SessionEvent {
        var data: [String: JSONValue] = ["id": .string(id), "toolName": .string("bash")]
        if let callId { data["callId"] = .string(callId) }
        return ev(seq, "approval/asked", data)
    }

    private func decided(_ seq: Int, id: String) -> SessionEvent {
        ev(seq, "approval/decided", ["id": .string(id), "outcome": .string("rejected")])
    }

    /// 残骸形态（真机原样）：`approval/asked` 后紧跟带错的 `tool/result`，
    /// 再 `step/end` → `turn/end`，中间无 `decided`。
    private func wreck(_ base: Int, id: String, callId: String) -> [SessionEvent] {
        [
            ev(base, "assistant/message"),
            ev(base + 1, "tool/call", ["name": .string("bash")]),
            asked(base + 2, id: id, callId: callId),
            ev(base + 3, "tool/result", ["error": .object(["code": .string("TOOL_OUTCOME_UNKNOWN")])]),
            ev(base + 4, "step/end"),
            ev(base + 5, "turn/end"),
        ]
    }

    private func sync(_ eventIds: [String], callIds: [String], stale: Bool = false) -> JSONValue {
        .object([
            "kind": .string("sync"),
            "eventIds": .array(eventIds.map { .string($0) }),
            "callIds": .array(callIds.map { .string($0) }),
            "stale": .bool(stale),
        ])
    }

    func testRebuild() {
        // Q1：崩溃残骸不建卡 —— 会话日志里 asked 没有 decided，但 turn 已闭合。
        var wrecked = ApprovalInbox()
        wrecked.rebuild(from: wreck(244, id: "b2dd61b1", callId: "call_00_ET_FiVdc"))
        XCTAssertTrue(wrecked.pending.isEmpty, "Q1 turn 已闭合的 asked（残骸）不建卡")

        // Q2：turn 未闭合的 asked 照常建卡 —— 那才是真的还挂着，不许误杀。
        var live = ApprovalInbox()
        live.rebuild(from: [
            ev(283, "assistant/message"),
            ev(284, "tool/call", ["name": .string("bash")]),
            asked(285, id: "c186c564", callId: "call_00_ET_Baq0u"),
        ])
        XCTAssertTrue(
            live.pending.count == 1 && live.pending.first?.id == "c186c564",
            "Q2 turn 未闭合的 asked 照常建卡"
        )

        // Q3：正常收口（asked + decided）不建卡 —— 既有行为，回归保护。
        var settled = ApprovalInbox()
        settled.rebuild(from: [
            asked(284, id: "c186c564", callId: "call_00_ET_Baq0u"),
            decided(285, id: "c186c564"),
        ])
        XCTAssertTrue(settled.pending.isEmpty, "Q3 asked 后 decided 收口，不建卡")

        // Q4：残骸与活审批共存 —— 只留活的那张（同一次重建里两种判定都要对）。
        var mixed = ApprovalInbox()
        mixed.rebuild(from:
            wreck(244, id: "b2dd61b1", callId: "call_00_ET_FiVdc")
            + [
                ev(290, "assistant/message"),
                asked(291, id: "cdf80c37", callId: "call_00_ET_Qnb7p"),
            ]
        )
        XCTAssertTrue(
            mixed.pending.count == 1 && mixed.pending.first?.id == "cdf80c37",
            "Q4 残骸与活审批共存时只留活的"
        )

        // Q5：窗口从 turn 中间截断（没有 turn/end）→ 保守建卡，宁可多问不可漏。
        var truncated = ApprovalInbox()
        truncated.rebuild(from: [
            asked(247, id: "b2dd61b1", callId: "call_00_ET_FiVdc"),
            ev(248, "tool/result"),
        ])
        XCTAssertTrue(truncated.pending.count == 1, "Q5 窗口截断（无 turn/end）时保守建卡")

        // Q6：权威名单到达 → 对账结论在同一次调用里生效，不必等下一次刷新。
        var reconciled = ApprovalInbox()
        reconciled.rebuild(from: [asked(247, id: "b2dd61b1", callId: "call_00_ET_FiVdc")])
        XCTAssertTrue(reconciled.pending.count == 1, "Q6a 收到名单前，未闭合的 asked 先建卡")
        reconciled.absorb(sync([], callIds: []))
        XCTAssertTrue(reconciled.pending.isEmpty, "Q6b 权威名单到达后，对账立即生效")

        // Q7：stale 名单不清卡 —— relay 未就绪时名单证明不了任何事。
        var stale = ApprovalInbox()
        stale.rebuild(from: [asked(247, id: "b2dd61b1", callId: "call_00_ET_FiVdc")])
        stale.absorb(sync([], callIds: [], stale: true))
        XCTAssertTrue(stale.pending.count == 1, "Q7 stale 名单不清卡")
    }

    /// 转发帧这一侧：`request` 绑定审计卡、`cancel` 撤卡。搬家后同样不需要客户端。
    func testForwardFrames() {
        var inbox = ApprovalInbox()
        inbox.rebuild(from: [asked(300, id: "audit-1", callId: "call_A")])
        XCTAssertEqual(inbox.pending.count, 1, "重建出一张审计卡")

        inbox.absorb(.object([
            "kind": .string("request"),
            "eventId": .string("wf-1"),
            "toolName": .string("bash"),
            "callId": .string("call_A"),
        ]))
        XCTAssertEqual(inbox.pending.count, 1, "同 callId 的转发帧绑定到审计卡，不新增第二张")
        XCTAssertEqual(inbox.pending.first?.id, "audit-1", "留下的是审计卡本身，不是新建的转发卡")
        XCTAssertEqual(inbox.pending.first?.eventId, "wf-1", "绑定后拿到可应答的寻址键")

        inbox.absorb(.object(["kind": .string("cancel"), "eventId": .string("wf-1")]))
        XCTAssertTrue(inbox.pending.isEmpty, "cancel 按 eventId 撤卡")
    }
}
