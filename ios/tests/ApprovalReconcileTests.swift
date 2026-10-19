/**
 * 待批审批的判定断言：Q1–Q7（事实来源与残骸），加转发帧与 R17 的断言（绑定活过重建 /
 * 收口不复活 / 四种到达顺序与同文两问 / 可应答性 / 名单与帧的先后 / 已答掉的不抢帧）。
 * 判定不碰网络、不碰界面，喂事件序列、转发帧与对账名单，看建出几张卡、带不带寻址键。
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

    private func asked(_ seq: Int, id: String, callId: String? = nil,
                       reason: String? = nil) -> SessionEvent {
        var data: [String: JSONValue] = ["id": .string(id), "toolName": .string("bash")]
        if let callId { data["callId"] = .string(callId) }
        if let reason { data["reason"] = .string(reason) }
        return ev(seq, "approval/asked", data)
    }

    /// 网关推给手机的一条 `approval` 帧。
    private func request(_ eventId: String, callId: String? = nil,
                         reason: String? = nil) -> JSONValue {
        var frame: [String: JSONValue] = ["kind": .string("request"),
                                          "eventId": .string(eventId),
                                          "toolName": .string("bash")]
        if let callId { frame["callId"] = .string(callId) }
        if let reason { frame["reason"] = .string(reason) }
        return .object(frame)
    }

    private func cancel(_ eventId: String) -> JSONValue {
        .object(["kind": .string("cancel"), "eventId": .string(eventId)])
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

        inbox.absorb(cancel("wf-1"))
        XCTAssertTrue(inbox.pending.isEmpty, "cancel 按 eventId 撤卡")
    }

    /// R17 V1：绑定是派生的 —— 转发帧到达后，无论再重建多少次，寻址键都不变。
    ///
    /// `refreshView` 每次都调 `rebuild`（事件帧按 16ms 窗口合批），所以「活过一次重算」不够。
    func testBindingSurvivesRebuild() {
        var inbox = ApprovalInbox()
        let events = [asked(300, id: "audit-1", callId: "call_A")]
        inbox.rebuild(from: events)
        inbox.absorb(request("wf-1", callId: "call_A"))
        XCTAssertEqual(inbox.pending.first?.eventId, "wf-1", "帧到达后绑定到审计卡")

        for round in 1...3 {
            inbox.rebuild(from: events)
            XCTAssertEqual(inbox.pending.count, 1, "第 \(round) 次重建后仍是一张卡")
            XCTAssertEqual(inbox.pending.first?.id, "audit-1", "第 \(round) 次重建后仍是审计卡")
            XCTAssertEqual(inbox.pending.first?.eventId, "wf-1", "第 \(round) 次重建后绑定仍在")
        }
    }

    /// R17 V2：已收口的提问不复活 —— `decided` / `cancel` / 本地应答三条路径各自之后，
    /// 重建都不再出卡，也不留下以转发帧为身份的独立卡。
    func testSettledCardsDoNotComeBack() {
        let events = [asked(300, id: "audit-1", callId: "call_A")]

        var byDecided = ApprovalInbox()
        byDecided.rebuild(from: events)
        byDecided.absorb(request("wf-1", callId: "call_A"))
        byDecided.rebuild(from: events + [decided(301, id: "audit-1")])
        XCTAssertTrue(byDecided.pending.isEmpty, "decided 之后，审计卡与它的转发帧都不再出现")

        var byCancel = ApprovalInbox()
        byCancel.rebuild(from: events)
        byCancel.absorb(request("wf-1", callId: "call_A"))
        byCancel.absorb(cancel("wf-1"))
        XCTAssertTrue(byCancel.pending.isEmpty, "cancel 当场撤卡")
        byCancel.rebuild(from: events)
        XCTAssertTrue(byCancel.pending.isEmpty, "cancel 之后重建不复活")

        var byLocal = ApprovalInbox()
        byLocal.rebuild(from: events)
        byLocal.absorb(request("wf-1", callId: "call_A"))
        byLocal.remove(id: "audit-1")
        XCTAssertTrue(byLocal.pending.isEmpty, "本地应答后撤卡")
        byLocal.rebuild(from: events)
        XCTAssertTrue(byLocal.pending.isEmpty, "本地应答后重建不复活")

        // turn/end：残骸的提问与它的帧都不出现（否则留一张按了得 unknown-approval 的卡）。
        var byTurnEnd = ApprovalInbox()
        byTurnEnd.rebuild(from: [asked(300, id: "audit-1")])
        byTurnEnd.absorb(request("wf-1"))
        byTurnEnd.rebuild(from: [asked(300, id: "audit-1"), ev(301, "turn/end")])
        XCTAssertTrue(byTurnEnd.pending.isEmpty, "turn/end 之后，残骸与它的帧都不出现")
    }

    /// R17 V3–V5：配对只有一处 —— 四种到达顺序都只出一张卡；同文的两次提问仍是两张卡。
    func testForwardFramePairing() {
        let events = [asked(300, id: "audit-1", callId: "call_A")]

        var frameFirstWithKey = ApprovalInbox()
        frameFirstWithKey.absorb(request("wf-1", callId: "call_A"))
        frameFirstWithKey.rebuild(from: events)
        assertSingleCard(frameFirstWithKey, id: "audit-1", eventId: "wf-1",
                         "帧先到、带 callId")

        var frameFirstNoKey = ApprovalInbox()
        frameFirstNoKey.absorb(request("wf-1"))
        frameFirstNoKey.rebuild(from: [asked(300, id: "audit-1")])
        assertSingleCard(frameFirstNoKey, id: "audit-1", eventId: "wf-1",
                         "帧先到、两侧都没有 callId")

        var cardFirstWithKey = ApprovalInbox()
        cardFirstWithKey.rebuild(from: events)
        cardFirstWithKey.absorb(request("wf-1", callId: "call_A"))
        cardFirstWithKey.rebuild(from: events)
        assertSingleCard(cardFirstWithKey, id: "audit-1", eventId: "wf-1",
                         "审计卡先到、带 callId")

        var cardFirstNoKey = ApprovalInbox()
        cardFirstNoKey.rebuild(from: [asked(300, id: "audit-1")])
        cardFirstNoKey.absorb(request("wf-1"))
        cardFirstNoKey.rebuild(from: [asked(300, id: "audit-1")])
        assertSingleCard(cardFirstNoKey, id: "audit-1", eventId: "wf-1",
                         "审计卡先到、两侧都没有 callId")

        // V4：两次真实提问文字相同、各有一个帧 —— 按顺序一一配，不是合成一张。
        let twins = [asked(300, id: "audit-1", reason: "跑测试"),
                     asked(301, id: "audit-2", reason: "跑测试")]
        var sameText = ApprovalInbox()
        sameText.rebuild(from: twins)
        sameText.absorb(request("wf-1", reason: "跑测试"))
        sameText.absorb(request("wf-2", reason: "跑测试"))
        sameText.rebuild(from: twins)
        XCTAssertEqual(sameText.pending.count, 2, "同文两次提问仍是两张卡")
        XCTAssertEqual(Set(sameText.pending.compactMap(\.eventId)), ["wf-1", "wf-2"],
                       "两张卡各绑一个帧，不共用同一个")

        // V5：同文但两侧 callId 不同 —— 两个不同的工具调用，不配。
        var differentKeys = ApprovalInbox()
        differentKeys.rebuild(from: [asked(300, id: "audit-1", callId: "call_A")])
        differentKeys.absorb(request("wf-1", callId: "call_B"))
        XCTAssertEqual(differentKeys.pending.count, 2, "键不同不配，各自一张卡")
        XCTAssertNil(differentKeys.pending.first(where: { $0.id == "audit-1" })?.eventId,
                     "审计卡拿不到别人的寻址键")

        // V3e：同文、旧的那条已收口、只有一个帧 —— 帧留给还挂着的那条。
        let staleThenFresh = [asked(300, id: "audit-1", reason: "跑测试"),
                              ev(301, "turn/end"),
                              asked(302, id: "audit-2", reason: "跑测试")]
        var openFirst = ApprovalInbox()
        openFirst.rebuild(from: staleThenFresh)
        openFirst.absorb(request("wf-1", reason: "跑测试"))
        openFirst.rebuild(from: staleThenFresh)
        XCTAssertEqual(openFirst.pending.count, 1, "只剩还挂着的那条")
        XCTAssertEqual(openFirst.pending.first?.id, "audit-2", "留下的是未收口的那条")
        XCTAssertEqual(openFirst.pending.first?.eventId, "wf-1", "唯一的帧给还挂着的提问")
    }

    private func assertSingleCard(_ inbox: ApprovalInbox, id: String, eventId: String,
                                  _ what: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(inbox.pending.count, 1, "\(what)：只出一张卡", file: file, line: line)
        XCTAssertEqual(inbox.pending.first?.id, id, "\(what)：留下审计卡", file: file, line: line)
        XCTAssertEqual(inbox.pending.first?.eventId, eventId, "\(what)：带着寻址键",
                       file: file, line: line)
    }

    /// R17 V6：可应答性与寻址键同源 —— 卡上出不出现按钮，读的是同一个 `canAnswer`。
    ///
    /// 视图那一半没有单测（`ApprovalCard` 的条件分支），由真机判据兜；这里咬住规则本身。
    func testCanAnswerFollowsAddressingKey() {
        var inbox = ApprovalInbox()
        inbox.rebuild(from: [asked(300, id: "audit-1")])
        XCTAssertEqual(inbox.pending.first?.canAnswer, false, "没有寻址键就不能应答")
        inbox.absorb(request("wf-1"))
        XCTAssertEqual(inbox.pending.first?.canAnswer, true, "配上帧之后可以应答")
    }

    /// R17 回归（审查 C1）：连接时对账说「上游此刻没有审批」，之后新产生的审批仍要出现。
    ///
    /// 名单只是连接那一刻的快照；帧才是「这一问此刻还挂着」的证据。
    func testApprovalAskedAfterSyncStillShowsUp() {
        var inbox = ApprovalInbox()
        inbox.absorb(sync([], callIds: []))
        inbox.rebuild(from: [asked(300, id: "audit-1", callId: "call_new")])
        inbox.absorb(request("wf-1", callId: "call_new"))
        XCTAssertEqual(inbox.pending.count, 1, "连接之后新产生的审批不能被名单滤掉")
        XCTAssertEqual(inbox.pending.first?.id, "audit-1", "留下审计卡")
        XCTAssertEqual(inbox.pending.first?.eventId, "wf-1", "并且可以应答")
    }

    /// R17 回归（审查 M1）：已答掉的提问不抢后来者的帧 —— 同文、缺 `callId` 时最明显。
    func testSettledAskDoesNotStealTheNextFrame() {
        var inbox = ApprovalInbox()
        let first = asked(300, id: "audit-1", reason: "跑测试")
        inbox.rebuild(from: [first])
        inbox.absorb(request("wf-1", reason: "跑测试"))
        inbox.remove(id: "audit-1")

        let both = [first, asked(301, id: "audit-2", reason: "跑测试")]
        inbox.rebuild(from: both)
        inbox.absorb(request("wf-2", reason: "跑测试"))
        inbox.rebuild(from: both)
        XCTAssertEqual(inbox.pending.count, 1, "只剩还挂着的那条")
        XCTAssertEqual(inbox.pending.first?.id, "audit-2", "已答掉的不再出现")
        XCTAssertEqual(inbox.pending.first?.eventId, "wf-2", "帧给了还挂着的那条")
    }
}
