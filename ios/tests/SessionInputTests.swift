/**
 * 输入单元自己的判据 —— 以 `SessionInput` 为被测对象，不经过编排层的转发面。
 *
 * 守的是「扣下的定稿怎么回来」：`takeFeed` 取走即清，被扣下的那一批已经消费过，
 * 没有重排队这一步它们就永久停在窗口里，屏幕上是**少一行**而不是报错。
 *
 * 三条前置不可省：草稿要活着、事件要经 `append` 真的进窗口、`verdict` 不是重置 ——
 * 少任何一条，`hold` 都是 no-op，断言会变成「空守」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionInputTests: XCTestCase {

    /// 一条定稿事件：`needsNaming` 认的是类型与 `surfaceOp`，其余字段不参与。
    private func settlementEvent(_ seq: Int, text: String = "正式正文") -> SessionEvent {
        SessionEvent(type: "assistant/message", seq: seq, time: Double(seq), data: .object([
            "turn": .number(1),
            "step": .number(1),
            "message": .object([
                "id": .string("m-\(seq)"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ]))
    }

    /// 未定稿基线：一个进行中的 attempt，还没有累积内容。
    private func liveBaseline() -> JSONValue {
        .object([
            "revision": .number(0),
            "activeAttempt": .object([
                "attemptId": .string("a-1"),
                "turn": .number(1),
                "step": .number(1),
                "nextIndex": .number(0),
                "stream": .array([]),
            ]),
        ])
    }

    /// 扣下的一条：点名之前不进下一批，也不从本批里消失。
    ///
    /// `takeFeed` 全交（过滤在喂食那一步），把它改到 `takeFeed` 里会让镜像层的契约用例红 ——
    /// 那是另一条判据，这里只钉「扣下不动本批」。
    func testHeldSettlementStaysInTheBatchUntilItIsNamed() {
        let input = SessionInput(sessionId: "s-1", control: nil)
        _ = input.apply(baseline: liveBaseline(), cursor: 0)
        XCTAssertEqual(input.liveAttemptId, "a-1", "草稿没活着 —— 下面 hold 会是 no-op")

        let event = settlementEvent(0)
        input.hold(event, verdict: input.append(event))

        XCTAssertTrue(input.isHeld(0), "草稿开着时定稿该被扣下")
        XCTAssertEqual(input.takeFeed().map(\.seq), [0], "扣下不该把这一批挖掉一条")

        let named = input.named(0)
        XCTAssertEqual(named?.seq, 0, "点名要交出那条记录本身")
        XCTAssertFalse(input.isHeld(0), "点名之后不再暂存")
    }

    /// 作废不等于丢弃：整批作废时要按 `seq` 排序排回下一批，否则永久少一行。
    func testDrainingHeldPutsEveryRecordBackIntoTheNextBatch() {
        let input = SessionInput(sessionId: "s-1", control: nil)
        _ = input.apply(baseline: liveBaseline(), cursor: 0)

        let first = settlementEvent(0)
        let second = settlementEvent(1)
        input.hold(first, verdict: input.append(first))
        input.hold(second, verdict: input.append(second))
        XCTAssertEqual(input.heldCount, 2)
        _ = input.takeFeed()

        input.drainHeld()

        XCTAssertEqual(input.heldCount, 0, "作废之后不留暂存")
        XCTAssertEqual(input.takeFeed().map(\.seq), [0, 1],
                       "作废不等于丢弃 —— 它们要按 seq 升序回到下一批")
    }

    /// 整段重建时的清场：只清暂存，不排回（窗口自己会清空）。
    func testClearingHeldLeavesNothingBehind() {
        let input = SessionInput(sessionId: "s-1", control: nil)
        _ = input.apply(baseline: liveBaseline(), cursor: 0)
        let event = settlementEvent(0)
        input.hold(event, verdict: input.append(event))
        XCTAssertEqual(input.heldCount, 1)

        input.clearHeld()

        XCTAssertEqual(input.heldCount, 0)
    }

    /// 没有活草稿时不扣：那时不存在「定稿比草稿先到」这件事。
    func testHoldIsANoOpWithoutALiveDraft() {
        let input = SessionInput(sessionId: "s-1", control: nil)

        input.hold(settlementEvent(0), verdict: .merged(added: 1))

        XCTAssertEqual(input.heldCount, 0, "草稿没开就扣，等于把这条永久藏起来")
    }
}
