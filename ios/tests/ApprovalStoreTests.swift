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

        private(set) var clients: [String] = []

        func answer(eventId: String, decision: ApprovalDecision, clientId: String) async throws {
            calls.append(eventId)
            clients.append(clientId)
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

    /// 一条**只有 clientId** 的流：不推任何货物，只回答「我叫什么」。
    ///
    /// 应答需要它，而它只从流上来（`ready` 之后由 `EventsStream` 记住）。用它把
    /// 「id 从哪来」与「应答带上它」这两件事分开：这里要测的是后者。
    @MainActor
    private final class ReadySink: PendingEventSink {
        var clientId: String?

        init(clientId: String?) { self.clientId = clientId }

        func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void { {} }
        func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onReady(_ handler: @escaping () -> Void) -> () -> Void { {} }
    }

    /// 一个已经挂上就绪流的 store —— 应答的路径需要 `clientId`。
    private func readyStore(_ answerer: any ApprovalAnswering, clientId: String? = "c1") -> ApprovalStore {
        let store = ApprovalStore(answerer: answerer)
        store.attach(sink: ReadySink(clientId: clientId))
        return store
    }

    /// 一条 `waterfall` 货物帧。
    private func waterfallFrame() throws -> InboundFrame {
        try frame(#"{"type":"waterfall","event":"approval/request","eventId":"e1","agentId":"s1","request":{"toolName":"bash"}}"#)
    }

    /// 一条 `ready` 货物帧 —— 现在不带代次。
    private func readyFrame() throws -> InboundFrame {
        try frame(#"{"type":"ready","clientId":"c1"}"#)
    }

    /// 把一段货物 JSON 包成 `value` 里的 item 帧。
    private func frame(_ valueJSON: String) throws -> InboundFrame {
        try XCTUnwrap(InboundFrame.decode(Data(#"{"type":"item","streamId":"e1","value":\#(valueJSON)}"#.utf8)))
    }

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
        let store = readyStore(FakeAnswerer())
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], decision: .allowedOnce)

        XCTAssertTrue(store.pending(in: "s1").isEmpty, "答完即走 —— 没有任何帧参与")
        XCTAssertNil(store.state(for: "e1"))
        // 同源断言：守的是「成功分支有没有说话」，不守文案 —— 文案坏了由 Display 那一侧的事管。
        XCTAssertEqual(store.notice(for: "s1"), ApprovalStore.deliveredNote(decision: .allowedOnce))
    }

    /// 传输失败：卡留着、转「结果未知」。断线的写操作是未知，不是失败 ——
    /// 移除了用户会以为答过，标成失败又抹掉了「可能已经到了」。
    func testATransportFailureLeavesTheCardAndMarksItUnknown() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(RpcClientError.notActivated)
        let store = readyStore(answerer)
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], decision: .allowedOnce)

        XCTAssertEqual(store.pending(in: "s1").count, 1)
        XCTAssertEqual(store.state(for: "e1"), .unknown)
    }

    /// 服务端拒了这次投递：卡留着并写明原因 —— 那个问题仍挂在网关的暂存里。
    func testARefusalByTheGatewayKeepsTheCardWithItsReason() async {
        let answerer = FakeAnswerer()
        answerer.outcome = .failure(refused("internal-error"))
        let store = readyStore(answerer)
        store.receive(waterfall())

        await store.answer(store.pending(in: "s1")[0], decision: .allowedOnce)

        XCTAssertEqual(store.pending(in: "s1").count, 1)
        XCTAssertEqual(store.state(for: "e1"), .refused("网关自身出错 —— 进程还活着，只是这次请求失败了。"))
    }

    // MARK: - 在途

    /// 第一次作答还没回来时再点一次：门只被调用一次。
    ///
    /// 守卫必须在**发出之前**置位。写在回包之后（今天就是这样）时，等待期间守卫是空的，
    /// 连点两次会发两次；第二次会把第一次的「已投递」冲成另一个结局。
    func testASecondTapWhileTheFirstIsInFlightDoesNothing() async {
        let answerer = FakeAnswerer()
        answerer.holdsFirstCall = true
        let store = readyStore(answerer)
        store.receive(waterfall())
        let entry = store.pending(in: "s1")[0]

        let first = Task { await store.answer(entry, decision: .allowedOnce) }
        for _ in 0..<500 {
            if !answerer.calls.isEmpty { break }
            await Task.yield()
        }
        XCTAssertEqual(answerer.calls, ["e1"], "第一次该已经发出")
        XCTAssertEqual(store.state(for: "e1"), .sending, "往返期间卡上说的是「正在发送」")

        await store.answer(entry, decision: .allowedOnce)
        XCTAssertEqual(answerer.calls, ["e1"], "第二次不该再发一次")

        answerer.release()
        await first.value
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "放行之后照常收口")
    }

    // MARK: - 接线

    /// 只数注册次数的订阅面替身。
    ///
    /// 为什么需要它：订阅面是窄协议，但真实现（`EventsStream`）的听众表是 private ⇒ 数不到
    /// 「注册了几次」，而这条契约正是「注册几次」。不数卡片：`ApprovalTable.absorb` 按
    /// `eventId` 覆盖，卡片数恒定，断言它会永远绿。
    @MainActor
    private final class SpySink: PendingEventSink {
        private(set) var registrations: [String] = []
        var clientId: String? = "c1"

        func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
            registrations.append("approval")
            return {}
        }

        /// 审批只订阅自己那一类 —— 这里不登记，序列里因此不该出现它。
        func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }

        func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void { {} }

        func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
            registrations.append("cancel")
            return {}
        }

        func onReady(_ handler: @escaping () -> Void) -> () -> Void {
            registrations.append("ready")
            return {}
        }
    }

    /// 挂第二次是空操作 —— 入口不唯一，而注册本身不幂等。
    ///
    /// 症状今天**看不见**（重复的听众被按 `eventId` 覆盖吸收了），所以只能数注册次数。
    /// 换实例重挂也不生效（闸只认「挂过」）：全仓只有一个 `EventsStream`，这条限制写进了
    /// `attach` 的注释。
    func testAttachingTwiceRegistersTheListenersOnce() {
        let sink = SpySink()
        let store = ApprovalStore(answerer: FakeAnswerer())

        store.attach(sink: sink)
        XCTAssertEqual(sink.registrations, ["approval", "cancel", "ready"],
                       "一次挂载注册两种货物 + 一个就绪听众")

        store.attach(sink: sink)
        XCTAssertEqual(sink.registrations, ["approval", "cancel", "ready"], "第二次不该再注册")
    }

    /// 三处接线一次断完：待答调用进表、撤回带走它、源失效清空。
    ///
    /// 三处各自能单独坏（而且坏了都不编译失败），所以各一条断言。
    func testAttachWiresTheApprovalPathAndSourceLoss() throws {
        let events = EventsStream()
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.attach(sink: EventsPendingSink(stream: events))

        events.handle(try waterfallFrame())
        XCTAssertEqual(store.pending(in: "s1").count, 1, "货物从流里进来就成了一条")

        events.handle(try frame(#"{"type":"cancel","eventId":"e1"}"#))
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "撤回那条货物把卡带走")

        events.handle(try waterfallFrame())
        XCTAssertEqual(store.pending(in: "s1").count, 1)
        events.handle(try readyFrame())
        XCTAssertTrue(store.pending(in: "s1").isEmpty,
                      "源失效清空：网关的上游没了，手里这些一条也答不了")
    }

    /// 无寻址的撤回删不掉任何东西：`eventId` 缺失或空串时留着卡。
    ///
    /// 寻址校验归消费方 —— 「认不出怎么办」是读法的一部分：审批的口径是留卡比误删强。
    func testACancelWithoutAnEventIdKeepsTheCard() throws {
        let events = EventsStream()
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.attach(sink: EventsPendingSink(stream: events))

        events.handle(try waterfallFrame())
        XCTAssertEqual(store.pending(in: "s1").count, 1)

        events.handle(try frame(#"{"type":"cancel"}"#))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "没带 eventId 的撤回删不掉任何东西")

        events.handle(try frame(#"{"type":"cancel","eventId":""}"#))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "空串同理 —— 留着这张卡比误删别人的强")
    }

    /// 每一条 `ready` 都整表替换 —— 网关在它之后紧跟着重放当前集合。
    ///
    /// 这条守的是「表没有跨代状态」：不做这一步，重连之后宿主已经不持有的卡会一直留着
    /// （重放只会覆盖仍存活的那些）。
    func testEveryReadyRebuildsTheTableFromTheReplay() throws {
        let events = EventsStream()
        let store = ApprovalStore(answerer: FakeAnswerer())
        store.attach(sink: EventsPendingSink(stream: events))

        store.receive(waterfall(eventId: "e9"))
        XCTAssertEqual(store.pending(in: "s1").count, 1, "断线之前收到的那一条还在")

        // 重连：先 ready（清表），再重放当前集合。
        events.handle(try readyFrame())
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "ready 是重建的界线")

        events.handle(try waterfallFrame())
        XCTAssertEqual(store.pending(in: "s1").map(\.eventId), ["e1"], "重放重建")
    }

    /// 在途期间被上游撤回：卡没了，也不该留下「已投递」这句没有指代的话。
    ///
    /// 那条撤销是从另一条路进来的（`cancel`），它把状态行一起清掉了；回答随后到达，
    /// 于是「成功」这一支面对的是一个已经不在的卡。
    func testACancelWhileTheAnswerIsInFlightLeavesNoNotice() async {
        let answerer = FakeAnswerer()
        answerer.holdsFirstCall = true
        let store = readyStore(answerer)
        store.receive(waterfall())
        let entry = store.pending(in: "s1")[0]

        let answer = Task { await store.answer(entry, decision: .allowedOnce) }
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

    /// 换代清空：卡、状态、说明一起没了。
    ///
    /// **必须先让三样都非空**，否则「清空后都没了」对从未置位的键恒真 —— 这条用例原先
    /// 断言的是两个从未存在过的身份（`e1` 从未置状态、`c2` 从未出现），两条都是恒真的。
    /// 造非空的三条路各走一次：成功应答写通知、传输失败留状态、卡本身在表里。
    func testClearDropsEveryEntryAndEveryState() async {
        let answerer = FakeAnswerer()
        let store = readyStore(answerer)
        store.receive(waterfall(session: "s1", eventId: "e1"))
        store.receive(waterfall(session: "s2", eventId: "e2"))

        guard let first = store.pending(in: "s1").first,
              let second = store.pending(in: "s2").first else {
            return XCTFail("前置：两张卡都该在表里")
        }
        // e1 走成功：撤卡 + 写一句说明。
        await store.answer(first, decision: .allowedOnce)
        // e2 走传输失败：卡留着、状态停在 `.unknown`。
        answerer.outcome = .failure(RpcClientError.notActivated)
        await store.answer(second, decision: .allowedOnce)

        // 正控：三样都真的非空 —— 少了这一步，下面的断言只是在测 nil == nil。
        XCTAssertNotNil(store.notice(for: "s1"), "成功应答该留下一条说明")
        XCTAssertNotNil(store.state(for: "e2"), "传输失败该留下一个状态行")
        XCTAssertFalse(store.pending(in: "s2").isEmpty, "失败不撤卡")

        store.clear()

        XCTAssertTrue(store.pending(in: "s1").isEmpty)
        XCTAssertTrue(store.pending(in: "s2").isEmpty)
        XCTAssertNil(store.state(for: "e2"), "状态行不留看不见的旧值")
        XCTAssertNil(store.notice(for: "s1"), "上一代的说明也过时了")
    }
}

// MARK: - 归属（判据 9 的后两段）

@MainActor
final class ApprovalOwnershipTests: XCTestCase {

    /// 假门之外的另一半：`clientId` 从流上取出来、原样交给作答门。
    ///
    /// 这条补的是 `EventsStream` 与 `ApprovalStore` 之间的那一跳 —— 两端各自有判据时，
    /// 「解出来又丢掉」正是不编译失败、也没有任何一条红的形状（本期之前它就是丢掉的）。
    func testTheAnswerCarriesTheClientIdFromTheStream() async throws {
        let events = EventsStream()
        let answerer = RecordingAnswerer()
        let store = ApprovalStore(answerer: answerer)
        store.attach(sink: EventsPendingSink(stream: events))

        // 先给一条 ready：id 从此住在流上。
        _ = events.handle(try frame(#"{"type":"item","streamId":"e1","value":{"type":"ready","clientId":"c-42"}}"#))
        XCTAssertEqual(events.clientId, "c-42", "流要记住它 —— 这是全仓唯一的来源")

        store.receive(waterfall())
        await store.answer(store.pending(in: "s1")[0], decision: .allowedOnce)

        XCTAssertEqual(answerer.clients, ["c-42"], "应答要带上最近一次 ready 的那个 id")
        XCTAssertTrue(store.pending(in: "s1").isEmpty, "前置：这一发是成功的")
    }

    /// 流还没就绪（或刚收起）：不发请求，卡转「结果未知」。
    ///
    /// 发出去的一发网关一定会拒（`not-owner`），而那对用户说的是「这条审批不是你的」——
    /// 一件不是事实的事。
    func testWithNoClientIdTheAnswerIsNotSent() async {
        let answerer = RecordingAnswerer()
        let store = ApprovalStore(answerer: answerer)
        store.attach(sink: EmptySink())

        store.receive(waterfall())
        await store.answer(store.pending(in: "s1")[0], decision: .allowedOnce)

        XCTAssertTrue(answerer.clients.isEmpty, "没有归属的键就不发 —— 这一发注定被拒")
        XCTAssertEqual(store.pending(in: "s1").count, 1, "卡留着：等 ready 之后它还能答")
        XCTAssertEqual(store.state(for: "e1"), .unknown, "状态如实说「不知道」，不是「被拒」")
    }

    /// `not-owner` 的处置是撤卡。
    ///
    /// 留着一张永远答不动的卡比撤掉更坏 —— 网关在重连时会重发仍未答的问题，撤掉不会丢。
    func testANotOwnerRefusalRemovesTheCardWithAnExplanation() async {
        let answerer = RecordingAnswerer()
        answerer.outcome = .failure(RpcClientError.refused(GatewayFailure(code: "not-owner", message: "gateway said so")))
        let store = ApprovalStore(answerer: answerer)
        store.attach(sink: ReadySink(clientId: "c-1"))

        store.receive(waterfall())
        await store.answer(store.pending(in: "s1")[0], decision: .allowedOnce)

        XCTAssertTrue(store.pending(in: "s1").isEmpty, "撤卡")
        XCTAssertNil(store.state(for: "e1"))
        XCTAssertEqual(store.notice(for: "s1"),
                       GatewayFailure(code: "not-owner", message: "").readableDescription)
    }

    // MARK: - 夹具

    @MainActor
    private final class RecordingAnswerer: ApprovalAnswering {
        private(set) var clients: [String] = []
        var outcome: Result<Void, Error> = .success(())

        func answer(eventId: String, decision: ApprovalDecision, clientId: String) async throws {
            clients.append(clientId)
            try outcome.get()
        }
    }

    /// 一条永远没就绪过的流。
    @MainActor
    private final class EmptySink: PendingEventSink {
        var clientId: String? { nil }
        func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void { {} }
        func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onReady(_ handler: @escaping () -> Void) -> () -> Void { {} }
    }

    @MainActor
    private final class ReadySink: PendingEventSink {
        var clientId: String?
        init(clientId: String?) { self.clientId = clientId }
        func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void { {} }
        func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onReady(_ handler: @escaping () -> Void) -> () -> Void { {} }
    }

    private func frame(_ json: String) throws -> InboundFrame {
        try XCTUnwrap(InboundFrame.decode(Data(json.utf8)))
    }

    private func waterfall(session: String = "s1", eventId: String = "e1") -> JSONValue {
        .object([
            "event": .string("approval/request"),
            "eventId": .string(eventId),
            "agentId": .string(session),
            "request": .object(["toolName": .string("bash")]),
        ])
    }
}
