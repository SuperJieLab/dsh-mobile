/**
 * 待答表的判定：收下、覆盖、移除、清空、按会话分组。
 *
 * 表只认识帧载荷 —— 不认识连接、不认识界面、不认识会话日志。喂一条 `approval` 载荷，
 * 看它建出哪几条、可不可应答、分到哪个会话。
 */
import Foundation
import XCTest

@testable import DshMobile

final class ApprovalTableTests: XCTestCase {

    /// 网关推来的一条待答调用 —— 上游 waterfall 的四个字段原样。
    ///
    /// `callId` 与 `eventId` 可以同时给：上游的 `request` 里就带着前者，而身份是后者 ——
    /// 两者取不同值时正是「按错字段建键」唯一能被看见的形状。
    private func waterfall(
        session: String? = "s1", eventId: String? = "e1", toolName: String? = "bash",
        reason: String? = "needs write", callId: String? = nil
    ) -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let toolName { body["toolName"] = .string(toolName) }
        if let reason { body["reason"] = .string(reason) }
        if let callId { body["callId"] = .string(callId) }
        var payload: [String: JSONValue] = [
            "event": .string("approval/request"),
            "request": .object(body),
        ]
        if let session { payload["agentId"] = .string(session) }
        if let eventId { payload["eventId"] = .string(eventId) }
        return .object(payload)
    }

    // MARK: - 收下

    /// 一条完整的请求落进表，卡上要的三个字段原样。
    func testARequestLandsWithItsFields() {
        var table = ApprovalTable()
        table.absorb(waterfall())

        XCTAssertEqual(table.pending(in: "s1"), [
            ApprovalTable.Entry(
                eventId: "e1", sessionId: "s1",
                toolName: "bash", reason: "needs write"
            ),
        ])
    }

    /// 身份就是投递编号：同一个 `eventId` 重投一次是覆盖，换一个编号就是新的一条。
    ///
    /// 上游重放同一批待答项时用的是**同一个** `eventId`，所以覆盖就够了；`callId` 不再
    /// 参与身份 —— 用它当键的话，`cancel`（只带 `eventId`）就删不掉以它建的那一条。
    func testTheDeliveryIdIsTheIdentity() {
        var table = ApprovalTable()
        table.absorb(waterfall(eventId: "e1"))
        table.absorb(waterfall(eventId: "e1"))
        XCTAssertEqual(table.pending(in: "s1").count, 1, "同一个编号重投只该有一条")

        table.absorb(waterfall(eventId: "e2"))
        XCTAssertEqual(table.pending(in: "s1").map(\.eventId), ["e1", "e2"],
                       "换了编号就是另一条 —— 上游不会为重投换号")
    }

    /// 同一条投递重复到达（重连重投）覆盖成一条，不长第二张。
    func testTheSameDeliveryArrivingThreeTimesIsOneEntry() {
        var table = ApprovalTable()
        table.absorb(waterfall())
        table.absorb(waterfall())
        table.absorb(waterfall())
        XCTAssertEqual(table.pending(in: "s1").count, 1)
    }

    /// 表的上界是「服务端实际挂起的条数」，不随事件数增长。
    func testTwentyDistinctQuestionsMakeTwentyEntries() {
        var table = ApprovalTable()
        for index in 0..<20 {
            table.absorb(waterfall(eventId: "e\(index)"))
        }
        XCTAssertEqual(table.pending(in: "s1").count, 20)
    }

    // MARK: - 分到哪个会话

    /// 分组键是帧自己说的会话，不是「当前打开的是哪一屏」。
    func testEntriesAreGroupedByTheSessionTheyCarry() {
        var table = ApprovalTable()
        table.absorb(waterfall(session: "s1", eventId: "e1"))
        table.absorb(waterfall(session: "s2", eventId: "e2"))

        XCTAssertEqual(table.pending(in: "s1").map(\.eventId), ["e1"])
        XCTAssertEqual(table.pending(in: "s2").map(\.eventId), ["e2"])
        XCTAssertTrue(table.pending(in: "s3").isEmpty)
    }

    // MARK: - 形状不全的载荷

    /// 读不出归属或地址的不建项。四个字段各缺一次，每次表都不变。
    func testMalformedPayloadsAreDroppedOneByOne() {
        var table = ApprovalTable()
        table.absorb(waterfall())
        let before = table.pending(in: "s1")

        table.absorb(waterfall(session: nil))
        table.absorb(waterfall(eventId: nil))
        table.absorb(waterfall(toolName: nil))
        table.absorb(.object(["kind": .number(1)]))

        // 读全表而不是 `pending(in: "s1")`：错收进**别的会话**的那一条，分组读法看不见。
        XCTAssertEqual(table.entries.count, 1, "四条不完整的载荷一条都不该收 —— 含挂在别处的")
        XCTAssertEqual(table.pending(in: "s1"), before, "已有的那条原样")
    }

    /// 认不出的载荷什么也不做 —— 未来可能加的种类不该改动这张表。
    func testUnknownPayloadsLeaveTheTableAlone() {
        var table = ApprovalTable()
        table.absorb(waterfall())
        let before = table.pending(in: "s1")

        table.absorb(.object(["kind": .string("question"), "sessionId": .string("s1")]))
        table.absorb(.object(["kind": .string("notice"), "eventId": .string("e1")]))
        table.absorb(.object([:]))
        table.absorb(.null)

        XCTAssertEqual(table.pending(in: "s1"), before)
    }

    // MARK: - 移除与清空

    /// 取消按 `eventId` 寻址：它可能指向一条早已不在表里的项，那时什么都不发生。
    func testCancelRemovesByEventIdAndToleratesAnUnknownOne() {
        var table = ApprovalTable()
        table.absorb(waterfall(eventId: "e1"))
        table.remove(eventId: "e9")
        XCTAssertEqual(table.pending(in: "s1").count, 1, "不认识的 eventId 不该误删")

        table.remove(eventId: "e1")
        XCTAssertTrue(table.pending(in: "s1").isEmpty)
    }

    /// 载荷里带 `callId` 也不改变身份：`cancel` 只带 `eventId`，用别的字段建键就删不掉。
    ///
    /// 这一条必须用**两个字段取不同值**的样本：`callId == eventId` 时，两种建键方式长得
    /// 一模一样，改错了也全绿。症状是「别人先答了，我的卡永远留着」。
    func testACancelStillRemovesTheEntryWhenThePayloadCarriesADifferentCallId() {
        var table = ApprovalTable()
        table.absorb(waterfall(eventId: "e1", callId: "call-9"))

        XCTAssertEqual(table.pending(in: "s1").map(\.eventId), ["e1"], "身份是投递编号，不是 callId")

        table.remove(eventId: "e1")
        XCTAssertTrue(table.pending(in: "s1").isEmpty, "cancel 只带 eventId —— 用 callId 建键时这一删落空")
    }

    /// 本地作答成功：手里有编号，直接按它删。
    func testRemovingByEventIdNeedsNothingElse() {
        var table = ApprovalTable()
        table.absorb(waterfall(eventId: "e1"))
        table.remove(eventId: "e1")
        XCTAssertTrue(table.pending(in: "s1").isEmpty)
    }

    /// 换代清空：之后重投一条就回来一条，没有残留。
    func testClearEmptiesEverySessionAndTheNextDeliveryRebuilds() {
        var table = ApprovalTable()
        table.absorb(waterfall(session: "s1", eventId: "e1"))
        table.absorb(waterfall(session: "s2", eventId: "e2"))

        table.clear()
        XCTAssertTrue(table.pending(in: "s1").isEmpty)
        XCTAssertTrue(table.pending(in: "s2").isEmpty)

        table.absorb(waterfall(session: "s1", eventId: "e1"))
        XCTAssertEqual(table.pending(in: "s1").count, 1)
        XCTAssertTrue(table.pending(in: "s2").isEmpty, "重投只带仍挂着的那几条")
    }
}
