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

    /// 网关推来的一条 `approval` 载荷（`request` 那一支）。
    private func request(
        session: String? = "s1", eventId: String? = "e1", toolName: String? = "bash",
        reason: String? = "needs write", callId: String? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = ["kind": .string("request")]
        if let session { payload["sessionId"] = .string(session) }
        if let eventId { payload["eventId"] = .string(eventId) }
        if let toolName { payload["toolName"] = .string(toolName) }
        if let reason { payload["reason"] = .string(reason) }
        if let callId { payload["callId"] = .string(callId) }
        return .object(payload)
    }

    private func cancel(_ eventId: String) -> JSONValue {
        .object(["kind": .string("cancel"), "eventId": .string(eventId)])
    }

    // MARK: - 收下

    /// 一条完整的请求落进表，四个字段原样 —— 卡上的每个字都来自这条帧。
    func testARequestLandsWithItsFourFields() {
        var table = ApprovalTable()
        table.absorb(request())

        XCTAssertEqual(table.pending(in: "s1"), [
            ApprovalTable.Entry(
                identity: "e1", sessionId: "s1", eventId: "e1",
                toolName: "bash", reason: "needs write"
            ),
        ])
    }

    /// 身份优先取 `callId`：上游换代后同一问会被重投，那一次带的是新的 `eventId`，
    /// 而 `callId` 不变 —— 按 `eventId` 建卡的话一次重连就让一张卡变两张。
    func testIdentityPrefersCallIdAndSurvivesANewDeliveryId() {
        var table = ApprovalTable()
        table.absorb(request(eventId: "e1", callId: "c1"))
        table.absorb(request(eventId: "e9", callId: "c1"))

        XCTAssertEqual(table.pending(in: "s1").count, 1, "同一问重投只该有一条")
        XCTAssertEqual(table.pending(in: "s1").first?.eventId, "e9", "寻址键要换成新的那一个")
    }

    /// 没有 `callId` 的请求按 `eventId` 认 —— 那是它唯一的身份。
    func testWithoutCallIdTheDeliveryIdIsTheIdentity() {
        var table = ApprovalTable()
        table.absorb(request(callId: nil))
        XCTAssertEqual(table.pending(in: "s1").first?.identity, "e1")
    }

    /// 同一条投递重复到达（重连重投）覆盖成一条，不长第二张。
    func testTheSameDeliveryArrivingThreeTimesIsOneEntry() {
        var table = ApprovalTable()
        table.absorb(request())
        table.absorb(request())
        table.absorb(request())
        XCTAssertEqual(table.pending(in: "s1").count, 1)
    }

    /// 表的上界是「服务端实际挂起的条数」，不随事件数增长。
    func testTwentyDistinctQuestionsMakeTwentyEntries() {
        var table = ApprovalTable()
        for index in 0..<20 {
            table.absorb(request(eventId: "e\(index)", callId: "c\(index)"))
        }
        XCTAssertEqual(table.pending(in: "s1").count, 20)
    }

    // MARK: - 分到哪个会话

    /// 分组键是帧自己说的会话，不是「当前打开的是哪一屏」。
    func testEntriesAreGroupedByTheSessionTheyCarry() {
        var table = ApprovalTable()
        table.absorb(request(session: "s1", eventId: "e1"))
        table.absorb(request(session: "s2", eventId: "e2"))

        XCTAssertEqual(table.pending(in: "s1").map(\.eventId), ["e1"])
        XCTAssertEqual(table.pending(in: "s2").map(\.eventId), ["e2"])
        XCTAssertTrue(table.pending(in: "s3").isEmpty)
    }

    // MARK: - 形状不全的载荷

    /// 读不出归属或地址的不建项。四个字段各缺一次，每次表都不变。
    func testMalformedPayloadsAreDroppedOneByOne() {
        var table = ApprovalTable()
        table.absorb(request())
        let before = table.pending(in: "s1")

        table.absorb(request(session: nil))
        table.absorb(request(eventId: nil))
        table.absorb(request(toolName: nil))
        table.absorb(.object(["kind": .number(1)]))

        XCTAssertEqual(table.count, 1, "四条不完整的载荷一条都不该收 —— 含挂在别处的")
        XCTAssertEqual(table.pending(in: "s1"), before, "已有的那条原样")
    }

    /// 认不出的载荷什么也不做：对账名单与未来可能加的种类都不该改动表。
    func testUnknownPayloadsLeaveTheTableAlone() {
        var table = ApprovalTable()
        table.absorb(request())
        let before = table.pending(in: "s1")

        table.absorb(.object(["kind": .string("sync"), "eventIds": .array([.string("e1")])]))
        table.absorb(.object(["kind": .string("question"), "sessionId": .string("s1")]))
        table.absorb(.object([:]))
        table.absorb(.null)

        XCTAssertEqual(table.pending(in: "s1"), before)
    }

    // MARK: - 移除与清空

    /// 取消按 `eventId` 寻址：它可能指向一条早已不在表里的项，那时什么都不发生。
    func testCancelRemovesByEventIdAndToleratesAnUnknownOne() {
        var table = ApprovalTable()
        table.absorb(request(eventId: "e1", callId: "c1"))
        table.absorb(cancel("e9"))
        XCTAssertEqual(table.pending(in: "s1").count, 1, "不认识的 eventId 不该误删")

        table.absorb(cancel("e1"))
        XCTAssertTrue(table.pending(in: "s1").isEmpty)
    }

    /// 本地作答成功时用的是身份（`callId` 优先），与取消的寻址键不同。
    func testRemovingByIdentityDoesNotNeedTheDeliveryId() {
        var table = ApprovalTable()
        table.absorb(request(eventId: "e1", callId: "c1"))
        table.remove(identity: "c1")
        XCTAssertTrue(table.pending(in: "s1").isEmpty)
    }

    /// 换代清空：之后重投一条就回来一条，没有残留。
    func testClearEmptiesEverySessionAndTheNextDeliveryRebuilds() {
        var table = ApprovalTable()
        table.absorb(request(session: "s1", eventId: "e1", callId: "c1"))
        table.absorb(request(session: "s2", eventId: "e2", callId: "c2"))

        table.clear()
        XCTAssertTrue(table.pending(in: "s1").isEmpty)
        XCTAssertTrue(table.pending(in: "s2").isEmpty)

        table.absorb(request(session: "s1", eventId: "e1", callId: "c1"))
        XCTAssertEqual(table.pending(in: "s1").count, 1)
        XCTAssertTrue(table.pending(in: "s2").isEmpty, "重投只带仍挂着的那几条")
    }
}
