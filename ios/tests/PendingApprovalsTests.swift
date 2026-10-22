/**
 * 待答表的宿主：把判定发布给界面，并把一次应答的三种结局翻成卡片状态。
 *
 * 表本身不认识客户端，所以这里用「作答门」这个窄面把发请求换成可注入的一行 ——
 * 三种结局（成功 / 已经不在了 / 没送到）各要一条断言，而它们只在网络那一层分得开。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class PendingApprovalsTests: XCTestCase {

    /// 可挂起、可指定结果、可计数的作答门。
    @MainActor
    private final class FakeAnswerer: ApprovalAnswering {
        private(set) var calls: [String] = []
        var outcome: Result<Void, Error> = .success(())
        /// 第一次调用挂在这里，直到测试放行 —— 「在途」需要一个能停住的往返。
        var holdsFirstCall = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var held = false

        func answer(eventId: String, allow: Bool, answerId: String) async throws {
            calls.append(eventId)
            if holdsFirstCall, !held {
                held = true
                await withCheckedContinuation { self.waiter = $0 }
            }
            try outcome.get()
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }
    }

    private func request(
        session: String = "s1", eventId: String = "e1", toolName: String = "bash",
        callId: String? = "c1"
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "kind": .string("request"), "sessionId": .string(session),
            "eventId": .string(eventId), "toolName": .string(toolName),
        ]
        if let callId { payload["callId"] = .string(callId) }
        return .object(payload)
    }

    private func refused(_ code: String) -> GatewayClientError {
        .refused(GatewayFailure(code: code, message: "gateway said so"))
    }

    // MARK: - 收下与发布

    /// 帧进来就发布出去，且按会话分组 —— 别的会话读不到。
    func testReceivedFramesArePublishedPerSession() {
        let store = PendingApprovals(answerer: FakeAnswerer())
        store.receive(request(session: "s1"))
        store.receive(request(session: "s2", eventId: "e2", callId: "c2"))

        XCTAssertEqual(store.pending(in: "s1").map(\.identity), ["c1"])
        XCTAssertEqual(store.pending(in: "s2").map(\.identity), ["c2"])
        XCTAssertTrue(store.pending(in: "s3").isEmpty)
    }

    /// 取消把那张卡与它的状态一起清掉 —— 状态字典里不该留看不见的旧值。
    func testCancelRemovesTheEntryAndItsAnswerState() {
        let store = PendingApprovals(answerer: FakeAnswerer())
        store.receive(request())
        store.receive(.object(["kind": .string("cancel"), "eventId": .string("e1")]))

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertNil(store.state(for: "c1"))
    }

    // MARK: - 作答：成功与三种失败

    /// 成功即移除，不等任何回流帧：上游先摘掉自己的投递再广播取消，应答者收不到自己的收口帧。
    func testASuccessfulAnswerRemovesTheEntryWithoutWaitingForAFrame() async {
        let store = PendingApprovals(answerer: FakeAnswerer())
        store.receive(request())

        await store.answer(store.pending(in: "s1")[0], allow: true)

        XCTAssertTrue(store.pending(in: "s1").isEmpty, "答完即走 —— 没有任何帧参与")
        XCTAssertNil(store.state(for: "c1"))
        // 同源断言：守的是「成功分支有没有说话」，不守文案 —— 文案坏了由 Display 那一侧的事管。
        XCTAssertEqual(store.notice(for: "s1"), PendingApprovals.deliveredNote(allow: true))
    }

    /// 「这条已经不在了」：移除并说明 —— 留着就是一张永远按不动的卡。
    func testAnAlreadyGoneApprovalIsRemovedWithAnExplanation() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(refused("unknown-approval"))
        let store = PendingApprovals(answerer: answerer)
        store.receive(request())

        await store.answer(store.pending(in: "s1")[0], allow: false)

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertNil(store.state(for: "c1"))
        XCTAssertEqual(store.notice(for: "s1"),
                       GatewayFailure(code: "unknown-approval", message: "")
                        .readableDescription)
    }

    /// 传输失败：卡留着、转「结果未知」。断线的写操作是未知，不是失败 ——
    /// 移除了用户会以为答过，标成失败又抹掉了「可能已经到了」。
    func testATransportFailureLeavesTheCardAndMarksItUnknown() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(GatewayClientError.notActivated)
        let store = PendingApprovals(answerer: answerer)
        store.receive(request())

        await store.answer(store.pending(in: "s1")[0], allow: true)

        XCTAssertEqual(store.pending(in: "s1").count, 1)
        XCTAssertEqual(store.state(for: "c1"), .unknown)
    }

    /// 服务端拒了这次投递：卡留着并写明原因 —— 那个问题仍挂在网关的暂存里。
    func testARefusalByTheGatewayKeepsTheCardWithItsReason() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(refused("internal-error"))
        let store = PendingApprovals(answerer: answerer)
        store.receive(request())

        await store.answer(store.pending(in: "s1")[0], allow: true)

        XCTAssertEqual(store.pending(in: "s1").count, 1)
        XCTAssertEqual(store.state(for: "c1"), .refused("网关自身出错 —— 进程还活着，只是这次请求失败了。"))
    }

    // MARK: - 在途

    /// 第一次作答还没回来时再点一次：门只被调用一次。
    ///
    /// 守卫必须在**发出之前**置位。写在回包之后（今天就是这样）时，等待期间守卫是空的，
    /// 连点两次会发两次；第二次得到 `unknown-approval`，把第一次的「已投递」冲成「已经不在了」。
    func testASecondTapWhileTheFirstIsInFlightDoesNothing() async {
        let answerer = FakeAnswerer()
        answerer.holdsFirstCall = true
        let store = PendingApprovals(answerer: answerer)
        store.receive(request())
        let entry = store.pending(in: "s1")[0]

        let first = Task { await store.answer(entry, allow: true) }
        for _ in 0..<500 {
            if !answerer.calls.isEmpty { break }
            await Task.yield()
        }
        XCTAssertEqual(answerer.calls, ["e1"], "第一次该已经发出")
        XCTAssertEqual(store.state(for: "c1"), .sending, "往返期间卡上说的是「正在发送」")

        await store.answer(entry, allow: true)
        XCTAssertEqual(answerer.calls, ["e1"], "第二次不该再发一次")

        answerer.release()
        await first.value
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "放行之后照常收口")
    }

    // MARK: - 清空

    /// 换代清空：卡与状态一起没了，之后重投一条就回来一条。
    func testClearDropsEveryEntryAndEveryState() {
        let store = PendingApprovals(answerer: FakeAnswerer())
        store.receive(request(session: "s1", eventId: "e1", callId: "c1"))
        store.receive(request(session: "s2", eventId: "e2", callId: "c2"))

        store.clear()

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertTrue(store.pending(in: "s2").isEmpty)
        XCTAssertNil(store.state(for: "c1"))
        XCTAssertNil(store.state(for: "c2"))
    }
}
