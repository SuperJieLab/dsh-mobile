/**
 * 乐观行单元自己的判据 —— 以 `SessionOptimist` 为被测对象，不经过编排层。
 *
 * 守的是三件事：行插进来落在哪儿、哪些号算「已上屏」、什么时候撤。
 * `nodes` 的合并与视图那一列另在 `SessionSyncTests` 从上层验，这里只看单元自己。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionOptimistTests: XCTestCase {

    /// 窗口前沿 —— 用例要能在插行之前改它。
    private final class Cursor {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    /// 一条带 `rpcId` 的持久用户消息 —— 打开帧里认领乐观行的就是它。
    private func record(_ seq: Int, rpcId: String) -> SessionRecord {
        SessionRecord(type: "user/message", event: SessionEvent(
            type: "user/message",
            seq: seq,
            time: Double(seq),
            data: .object([
                "id": .string("m-\(seq)"),
                "source": .object(["kind": .string("user"), "rpcId": .string(rpcId)]),
                "content": .array([.object(["type": .string("text"), "text": .string("持久行")])]),
            ])
        ))
    }

    /// 插一行，位置落在「最后一条持久事件之后、首块草稿之前」。
    ///
    /// 前沿 2 ⇒ 锚点 1.25 起（`max(0, 2-1) + 0.25`）；首块草稿在 `2 - 0.5 = 1.5`。
    func testInsertingARowLandsBetweenTheLastDurableEventAndTheFirstDraftBlock() {
        let optimist = SessionOptimist(frontier: { 2 })

        optimist.insert(text: "hi", requestId: "r-1", time: 1000)

        XCTAssertEqual(optimist.count, 1)
        let anchor = optimist.entries.first?.anchorSeq ?? .nan
        // 1.25 = frontier - 1 + 0.25；首条的序号步长再加 0.001。断到具体值才守得住
        // 「0.25 这个偏移」—— 只断 `> 1.0` 的话，把它改成 0.1 照样绿。
        XCTAssertEqual(anchor, 1.251, accuracy: 0.0005,
                       "锚点不是 frontier-1 加 0.25（含首条的 0.001 步长）")
        XCTAssertLessThan(anchor, 1.5, "落在首块草稿之后了 —— 草稿会排到这条消息前面")
    }

    /// 锚点读的是插行那一刻的前沿，不是构造时的那一个。
    ///
    /// 两者必须同一拍：窗口在「算锚点」与「插行」之间前进过的话，行会落在已经到手
    /// 的持久事件之前。
    func testTheAnchorReadsTheFrontierWhenTheRowIsInserted() {
        let cursor = Cursor(2)
        let optimist = SessionOptimist(frontier: { cursor.value })
        optimist.insert(text: "第一条", requestId: "r-1", time: 1000)

        cursor.value = 6
        optimist.insert(text: "第二条", requestId: "r-2", time: 2000)

        let second = optimist.entries.last?.anchorSeq ?? .nan
        XCTAssertGreaterThan(second, 5.0, "锚点用的是构造时的前沿 —— 第二条会落在历史中间")
        XCTAssertLessThan(second, 5.5, "锚点越过了首块草稿的位置")
    }

    /// 凭空一个号不该撤掉任何行。
    ///
    /// 水位回退那一帧会带一个本地没有的 `rpcId` 到达 —— 那时上面的过滤要顶住，
    /// 否则屏幕上那条刚发的消息凭空消失。
    func testRetiringWithAnUnknownClaimRemovesNothing() {
        let optimist = SessionOptimist(frontier: { 2 })
        optimist.insert(text: "hi", requestId: "r-1", time: 1000)

        optimist.noteClaimed("r-unknown")
        optimist.retire()

        XCTAssertEqual(optimist.entries.map(\.requestId), ["r-1"],
                       "没插过的号把行撤掉了 —— 消息凭空消失")

        optimist.noteClaimed("r-1")
        optimist.retire()
        XCTAssertEqual(optimist.count, 0, "本号认领之后该撤")
    }

    /// 退休只撤「已上屏」的那些，两条记账入口（打开帧的持久行、落定的认领）行为一致。
    func testRetireRemovesOnlyTheSettledRows() {
        let optimist = SessionOptimist(frontier: { 2 })
        optimist.insert(text: "甲", requestId: "r-1", time: 1000)
        optimist.insert(text: "乙", requestId: "r-2", time: 2000)
        optimist.insert(text: "丙", requestId: "r-3", time: 3000)

        // 甲来自打开帧，乙来自事件帧，丙没人认领。
        optimist.noteDurable([record(0, rpcId: "r-1")])
        XCTAssertEqual(optimist.count, 3, "记账就当场撤了 —— 中间会空一帧")
        optimist.noteClaimed("r-2")
        optimist.retire()

        XCTAssertEqual(optimist.entries.map(\.requestId), ["r-3"],
                       "退休撤错了 —— 没被认领的那条要留着")
    }

    /// 整段重建只清「已上屏待退休」那本账，行一条不少。
    ///
    /// 清行等于让「用户刚发、宿主还没回应」的那条消息凭空消失。
    func testClearingSettledKeepsEveryRow() {
        let optimist = SessionOptimist(frontier: { 2 })
        optimist.insert(text: "甲", requestId: "r-1", time: 1000)
        optimist.insert(text: "乙", requestId: "r-2", time: 2000)
        optimist.noteDurable([record(0, rpcId: "r-1")])

        optimist.clearSettled()

        XCTAssertEqual(optimist.entries.map(\.requestId), ["r-1", "r-2"], "清账不该撤行")
        // 账清了：此后再叫退休，那些行一个也不该动（下一次物化会重新记账）。
        optimist.retire()
        XCTAssertEqual(optimist.count, 2, "清账之后退休还撤了行 —— 账没清干净")

        // 序号只增不减：重建之后再发一条，锚点必须比在屏的这一条更大 —— 复位会让新行
        // 插到已有行前面去（两条都叫 1.251，排序变成不稳定）。
        let lastAnchor = optimist.entries.last?.anchorSeq ?? .nan
        optimist.insert(text: "丙", requestId: "r-3", time: 3000)
        let fresh = optimist.entries.last?.anchorSeq ?? .nan
        XCTAssertGreaterThan(fresh, lastAnchor, "序号跟着重建回零了 —— 新行会插到已有行前面")
    }
}
