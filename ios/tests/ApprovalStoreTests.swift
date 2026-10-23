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
final class ApprovalStoreTests: XCTestCase {

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

    /// 一条待答调用的载荷 —— 上游 waterfall 的四个字段原样，网关只搬不改。
    ///
    /// `callId` 与 `eventId` 可以不同值 —— 那是「按错字段建键」唯一能被看见的形状。
    private func waterfall(
        session: String = "s1", eventId: String = "e1", toolName: String = "bash",
        reason: String? = nil, callId: String? = nil
    ) -> JSONValue {
        var body: [String: JSONValue] = ["toolName": .string(toolName)]
        if let reason { body["reason"] = .string(reason) }
        if let callId { body["callId"] = .string(callId) }
        return .object([
            "event": .string("approval/request"),
            "eventId": .string(eventId),
            "agentId": .string(session),
            "request": .object(body),
        ])
    }

    private func refused(_ code: String) -> RpcClientError {
        .refused(GatewayFailure(code: code, message: "gateway said so"))
    }

    // MARK: - 收下与发布

    /// 帧进来就按会话分组 —— 别的会话读不到。
    func testReceivedFramesAreGroupedBySession() {
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.receive(waterfall(session: "s1"))
        store.receive(waterfall(session: "s2", eventId: "e2"))

        XCTAssertEqual(store.pending(in: "s1").map(\.eventId), ["e1"])
        XCTAssertEqual(store.pending(in: "s2").map(\.eventId), ["e2"])
        XCTAssertTrue(store.pending(in: "s3").isEmpty)
    }

    /// 取消把那张卡与它的状态一起清掉 —— 状态字典里不该留看不见的旧值。
    func testCancelRemovesTheEntryAndItsAnswerState() {
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.receive(waterfall())
        store.cancel(eventId: "e1")

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertNil(store.state(for: "e1"))
    }

    /// 载荷里带 `callId` 也不改变身份：`cancel` 只带 `eventId`，用别的字段建键就删不掉。
    ///
    /// 样本必须让两个字段取**不同值** —— 相同时两种建键长得一模一样，改错了也全绿。
    /// 症状是「别人先答了，我的卡永远留着」。
    func testACancelStillRemovesTheEntryWhenThePayloadCarriesADifferentCallId() {
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.receive(waterfall(eventId: "e1", callId: "call-9"))
        XCTAssertEqual(store.pending(in: "s1").map(\.eventId), ["e1"], "身份是投递编号，不是 callId")

        store.cancel(eventId: "e1")
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "cancel 只带 eventId —— 用 callId 建键时这一删落空")
    }

    // MARK: - 作答：成功与三种失败

    /// 成功即移除，不等任何回流帧：上游先摘掉自己的投递再广播取消，应答者收不到自己的收口帧。
    func testASuccessfulAnswerRemovesTheEntryWithoutWaitingForAFrame() async {
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], allow: true)

        XCTAssertTrue(store.pending(in: "s1").isEmpty, "答完即走 —— 没有任何帧参与")
        XCTAssertNil(store.state(for: "e1"))
        // 同源断言：守的是「成功分支有没有说话」，不守文案 —— 文案坏了由 Display 那一侧的事管。
        XCTAssertEqual(store.notice(for: "s1"), ApprovalStore.deliveredNote(allow: true))
    }

    /// 「这条已经不在了」：移除并说明 —— 留着就是一张永远按不动的卡。
    func testAnAlreadyGoneApprovalIsRemovedWithAnExplanation() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(refused("unknown-approval"))
        let store = ApprovalStore(answerer: answerer)
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], allow: false)

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertNil(store.state(for: "e1"))
        XCTAssertEqual(store.notice(for: "s1"),
                       GatewayFailure(code: "unknown-approval", message: "")
                        .readableDescription)
    }

    /// 传输失败：卡留着、转「结果未知」。断线的写操作是未知，不是失败 ——
    /// 移除了用户会以为答过，标成失败又抹掉了「可能已经到了」。
    func testATransportFailureLeavesTheCardAndMarksItUnknown() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(RpcClientError.notActivated)
        let store = ApprovalStore(answerer: answerer)
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], allow: true)

        XCTAssertEqual(store.pending(in: "s1").count, 1)
        XCTAssertEqual(store.state(for: "e1"), .unknown)
    }

    /// 服务端拒了这次投递：卡留着并写明原因 —— 那个问题仍挂在网关的暂存里。
    func testARefusalByTheGatewayKeepsTheCardWithItsReason() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(refused("internal-error"))
        let store = ApprovalStore(answerer: answerer)
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], allow: true)

        XCTAssertEqual(store.pending(in: "s1").count, 1)
        XCTAssertEqual(store.state(for: "e1"), .refused("网关自身出错 —— 进程还活着，只是这次请求失败了。"))
    }

    // MARK: - 在途

    /// 第一次作答还没回来时再点一次：门只被调用一次。
    ///
    /// 守卫必须在**发出之前**置位。写在回包之后（今天就是这样）时，等待期间守卫是空的，
    /// 连点两次会发两次；第二次得到 `unknown-approval`，把第一次的「已投递」冲成「已经不在了」。
    func testASecondTapWhileTheFirstIsInFlightDoesNothing() async {
        let answerer = FakeAnswerer()
        answerer.holdsFirstCall = true
        let store = ApprovalStore(answerer: answerer)
        store.receive(waterfall())
        let entry = store.pending(in: "s1")[0]

        let first = Task { await store.answer(entry, allow: true) }
        for _ in 0..<500 {
            if !answerer.calls.isEmpty { break }
            await Task.yield()
        }
        XCTAssertEqual(answerer.calls, ["e1"], "第一次该已经发出")
        XCTAssertEqual(store.state(for: "e1"), .sending, "往返期间卡上说的是「正在发送」")

        await store.answer(entry, allow: true)
        XCTAssertEqual(answerer.calls, ["e1"], "第二次不该再发一次")

        answerer.release()
        await first.value
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "放行之后照常收口")
    }

    // MARK: - 接线

    /// 三处接线一次断完：待答调用进表、撤回带走它、源失效清空。
    ///
    /// 三处各自能单独坏（而且坏了都不编译失败），所以各一条断言。
    func testAttachWiresTheApprovalPathAndSourceLoss() {
        let events = ConnectionEventStream()
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.attach(events: events)

        events.handle(ConnectionEventReading(content: .cargo(type: "waterfall", payload: waterfall())))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "货物从流里进来就成了一条")

        events.handle(ConnectionEventReading(content: .cargo(type: "cancel", payload: .object(["eventId": .string("e1")]))))
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "撤回那条货物把卡带走")

        events.handle(ConnectionEventReading(content: .cargo(type: "waterfall", payload: waterfall())))
        XCTAssertEqual(store.pending(in: "s1").count, 1)
        events.handle(ConnectionEventReading(content: .ready(generation: nil)))
        XCTAssertTrue(store.pending(in: "s1").isEmpty,
                      "源失效清空：网关的上游没了，手里这些一条也答不了")
    }

    /// 无寻址的撤回删不掉任何东西：`eventId` 缺失或空串时留着卡。
    ///
    /// 寻址校验归消费方 —— 「认不出怎么办」是读法的一部分：审批的口径是留卡比误删强。
    func testACancelWithoutAnEventIdKeepsTheCard() throws {
        let events = ConnectionEventStream()
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.attach(events: events)

        events.handle(ConnectionEventReading(content: .cargo(type: "waterfall", payload: waterfall())))
        XCTAssertEqual(store.pending(in: "s1").count, 1)

        events.handle(ConnectionEventReading(content: .cargo(type: "cancel", payload: .object([:]))))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "没带 eventId 的撤回删不掉任何东西")

        events.handle(ConnectionEventReading(content: .cargo(
            type: "cancel", payload: .object(["eventId": .string("")])
        )))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "空串同理 —— 留着这张卡比误删别人的强")

        // 丢弃要有留痕：没有它，「卡没少」与「这条撤回被丢了」在屏幕上分不出来。
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Approval/State/ApprovalStore.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("dropped a cancel without an eventId"),
                      "留痕句不在了 —— 无寻址撤回被丢弃时现场只剩这一行")
    }

    /// 每一条 `ready` 都整表替换 —— 网关在它之后紧跟着重放当前集合。
    ///
    /// 这条守的是「表没有跨代状态」：不做这一步，重连之后宿主已经不持有的卡会一直留着
    /// （重放只会覆盖仍存活的那些）。
    func testEveryReadyRebuildsTheTableFromTheReplay() {
        let events = ConnectionEventStream()
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.attach(events: events)

        store.receive(waterfall(eventId: "e9"))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "断线之前收到的那一条还在")

        // 重连：先 ready（清表），再重放当前集合。
        events.handle(ConnectionEventReading(content: .ready(generation: 7)))
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "ready 是重建的界线")

        events.handle(ConnectionEventReading(content: .cargo(type: "waterfall", payload: waterfall())))
        XCTAssertEqual(store.pending(in: "s1").map(\.eventId), ["e1"], "重放重建")
    }

    /// 在途期间被上游撤回：卡没了，也不该留下「已投递」这句没有指代的话。
    ///
    /// 那条撤销是从另一条路进来的（`cancel`），它把状态行一起清掉了；回答随后到达，
    /// 于是「成功」这一支面对的是一个已经不在的卡。
    func testACancelWhileTheAnswerIsInFlightLeavesNoNotice() async {
        let answerer = FakeAnswerer()
        answerer.holdsFirstCall = true
        let store = ApprovalStore(answerer: answerer)
        store.receive(waterfall())
        let entry = store.pending(in: "s1")[0]

        let answer = Task { await store.answer(entry, allow: true) }
        for _ in 0..<500 {
            if !answerer.calls.isEmpty { break }
            await Task.yield()
        }
        store.cancel(eventId: "e1")
        answerer.release()
        await answer.value

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertNil(store.state(for: "e1"))
        XCTAssertNil(store.notice(for: "s1"), "卡都不在了，那句话没有指代")
    }

    // MARK: - 清空

    /// 换代清空：卡与状态一起没了，之后重投一条就回来一条。
    func testClearDropsEveryEntryAndEveryState() {
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.receive(waterfall(session: "s1", eventId: "e1"))
        store.receive(waterfall(session: "s2", eventId: "e2"))

        store.clear()

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertTrue(store.pending(in: "s2").isEmpty)
        XCTAssertNil(store.state(for: "e1"))
        XCTAssertNil(store.state(for: "c2"))
        XCTAssertNil(store.notice(for: "s1"), "上一代的说明也过时了")
    }
}
