/**
 * 流表的**流级**行为：编号、开与关、换号重开、按流退避、就绪超时、建成集合。
 *
 * 这一组判据全部落在 `StreamMux` + 一个假端口上，**不需要 socket、不碰 URLSession** ——
 * 「流层能脱离传输被完整断言」这件事由它们的存在本身证明。
 *
 * 为什么值得单独断言：这些事**不会编译失败**。编号复用了、注销关错了流、退避到点重发了
 * 同一个号、就绪超时把已经建成的流判成没成 —— 四种都表现为屏幕上的偶然
 *（「切会话后停在正在同步」「旧会话的内容闪一下」「连着却突然断」），真机看得见但说不清。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class StreamMuxTests: XCTestCase {

    // MARK: - 替身

    /// 传输层的替身：只记账，不做判定。
    private final class FakePort: StreamPort {
        var sent: [String] = []
        var ensureCount = 0
        var abandonCount = 0
        var establishCount = 0
        var attempt: StreamAttempt?

        /// 假装已经有一条连接（第 `generation` 代）。令牌的身份用本对象自己。
        func attachConnection(generation: Int = 1) {
            attempt = StreamAttempt(generation: generation, connection: self)
        }

        func send(_ text: String) { sent.append(text) }
        func ensureConnected() { ensureCount += 1 }
        func abandon(_ reason: AbandonReason, attempt: StreamAttempt) {
            abandonCount += 1
        }
        func didEstablish() { establishCount += 1 }
    }

    /// 业务判读的替身：给什么答复就是什么答复。
    private final class FakeBehavior: StreamBehavior {
        let label: String
        var built: [StreamId] = []
        var handled = 0
        /// 这次造流的 `build` 是否抛错（形状自己坏了那种）。
        var buildFails = false
        /// 每一帧的答复，默认什么都不做。
        var verdict: (MuxServerEnvelope) -> StreamReply = { _ in StreamReply() }

        init(label: String = "s1") { self.label = label }

        func build(_ id: StreamId) throws -> String {
            if buildFails { throw GatewayClientError.malformedResponse(detail: "test") }
            built.append(id)
            return #"{"type":"open","streamId":"\#(id)"}"#
        }

        func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply {
            handled += 1
            return verdict(envelope)
        }
    }

    private func makeMux() -> (StreamMux, FakePort) {
        let port = FakePort()
        let mux = StreamMux()
        mux.attach(port: port)
        return (mux, port)
    }

    private func frame(_ id: StreamId) -> MuxServerEnvelope {
        MuxServerEnvelope(type: "item", streamId: id, payload: nil)
    }

    // MARK: - S1：造流 = 一个编号 + 一条 open

    func testMakingAStreamMintsOneIdAndSendsOneOpen() throws {
        let (mux, port) = makeMux()
        port.attachConnection()

        let stream = try XCTUnwrap(mux.makeStream(FakeBehavior()))

        XCTAssertFalse(stream.id.isEmpty, "编号由流表造，不能为空")
        XCTAssertEqual(port.sent.count, 1, "造一条流恰好发一条 open")
        XCTAssertTrue(port.sent[0].contains(stream.id), "发出去的文本里是刚造的那个号")
        XCTAssertEqual(port.ensureCount, 0, "已有连接时不该再要一条")
    }

    /// 没有连接时：登记好、**不发帧**，而是让传输层去建一条。
    func testMakingAStreamWithoutAConnectionAsksForOne() throws {
        let (mux, port) = makeMux()

        let stream = try XCTUnwrap(mux.makeStream(FakeBehavior()))

        XCTAssertEqual(port.sent, [], "没有连接就一个字节都不发")
        XCTAssertEqual(port.ensureCount, 1, "登记之后要让传输层建一条")
        XCTAssertFalse(stream.id.isEmpty)
    }

    // MARK: - S2：对象化之后 makeStream 不幂等

    /// 同一业务造两次就是两条流、两个号。流以对象自身为身份，所以「重复调用安全」
    /// 不再成立 —— **业务要负责只造一次**（各自的一次性闸）。
    func testMakingTwiceYieldsTwoStreamsWithDifferentIds() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()

        let first = try XCTUnwrap(mux.makeStream(behavior))
        let second = try XCTUnwrap(mux.makeStream(behavior))

        XCTAssertNotEqual(first.id, second.id, "两次造流必须是两个号")
        XCTAssertEqual(port.sent.count, 2, "两条流各发一条 open")
    }

    /// `build` 抛错：不造流、不发帧 —— 开一条注定看不懂的流只会让屏幕停在「正在同步…」。
    func testAFailingBuildMakesNoStream() {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()
        behavior.buildFails = true

        XCTAssertNil(mux.makeStream(behavior), "编不出开流文本时不造流")
        XCTAssertEqual(port.sent, [])
        XCTAssertFalse(mux.hasPendingOpening)
    }

    // MARK: - S3：注销只碰自己、幂等

    func testClosingSendsOneCancelForItsOwnIdAndIsIdempotent() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let first = try XCTUnwrap(mux.makeStream(FakeBehavior(label: "a")))
        let secondBehavior = FakeBehavior(label: "b")
        let second = try XCTUnwrap(mux.makeStream(secondBehavior))

        mux.close(first)
        XCTAssertEqual(port.sent.count, 3, "两条 open + 一条 cancel")
        XCTAssertTrue(port.sent.last?.contains(first.id) == true, "取消帧指向自己那个号")
        XCTAssertTrue(port.sent.last?.contains(second.id) == false, "不碰另一条流")

        mux.close(first)
        XCTAssertEqual(port.sent.count, 3, "关第二次什么都不发")

        // 另一条流还在：它的帧仍然进判读器。
        mux.receive(frame(second.id), raw: Data())
        XCTAssertEqual(secondBehavior.handled, 1, "另一条流照常收帧")
    }

    // MARK: - S4：重开先取消旧号、再换新号

    func testRestartCancelsTheOldIdThenOpensWithAFreshOne() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let oldId = stream.id

        stream.restart()

        XCTAssertNotEqual(stream.id, oldId, "重开必须换号")
        XCTAssertEqual(port.sent.count, 3, "open(旧) + cancel(旧) + open(新)")
        XCTAssertTrue(port.sent[1].contains(oldId), "第二条是取消旧号")
        XCTAssertTrue(port.sent[2].contains(stream.id), "第三条用新号开出去")
        XCTAssertEqual(behavior.built, [oldId, stream.id], "文本按新号重拼过一次")
    }

    // MARK: - S5：被拒按自己的退避重试

    func testARefusalRenumbersImmediatelyAndSchedulesARetry() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(next: .retry) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let oldId = stream.id

        mux.receive(frame(oldId), raw: Data())

        XCTAssertNotEqual(stream.id, oldId, "被拒之后当场换号（新号等退避到了再发）")
        XCTAssertEqual(port.sent.count, 2, "open(旧) + cancel(旧)；新号还没有发出去")
        XCTAssertTrue(mux.isWaitingToRetry(stream), "这一拍退避真的排上了")
    }

    /// 退避到点那一拍要不要真的发 open：两个条件各挡一种重复。
    ///
    /// **在途**挡「同一个号被开两次」——网关把重复编号判成协议违规、直接关连接；
    /// **已建成**挡「没必要的重开」。两种都不是「退避错了」，而是这一拍已被别的东西
    ///（重连、或用户手按的重试）提前满足了。
    func testTheRetryTickOnlyFiresOnAnIdleUnbuiltStream() {
        XCTAssertTrue(StreamMux.shouldOpenOnRetry(openInFlight: false, established: false))
        XCTAssertFalse(StreamMux.shouldOpenOnRetry(openInFlight: true, established: false))
        XCTAssertFalse(StreamMux.shouldOpenOnRetry(openInFlight: false, established: true))
        XCTAssertFalse(StreamMux.shouldOpenOnRetry(openInFlight: true, established: true))
    }

    // MARK: - S6：就绪超时的判据是「还是这一次尝试」

    func testTheReadyTimeoutAbandonsTheConnectionOnce() async throws {
        let (mux, port) = makeMux()
        mux.readyTimeout = 0.05
        port.attachConnection(generation: 3)
        _ = mux.makeStream(FakeBehavior())

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(port.abandonCount, 1, "45 秒（此处拨到 50ms）没等到开口帧 ⇒ 放弃一次")
    }

    /// 就绪硬超时的值是算出来的，不是抄来的。
    ///
    /// 它必须盖住「最慢链路上传完承诺上界」所需的时间：抄上游 15s 的那版在真机上活不过
    /// 1.25 MB 的打开帧。判据钉的是这个关系，不是某个魔法数 —— 改小它会当场红。
    func testTheReadyTimeoutCoversTheSlowestLink() {
        let worstCaseSeconds = Double(4 * 1024 * 1024) / (125 * 1024)   // 4 MiB ÷ 125 KB/s ≈ 33.6s
        let timeout = StreamMux().readyTimeout
        XCTAssertGreaterThanOrEqual(timeout, worstCaseSeconds,
                                    "盖不住最慢链路时，大窗口会被自己掐断")
        XCTAssertEqual(timeout, 45, "取值 = 33.6s + 建连 ~2s，取整到 45s")
    }

    /// 期间建成了：不再放弃。
    func testAnEstablishedStreamDisarmsTheReadyTimeout() async throws {
        let (mux, port) = makeMux()
        mux.readyTimeout = 0.05
        port.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(establishes: true) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))

        mux.receive(frame(stream.id), raw: Data())
        XCTAssertEqual(port.establishCount, 1, "建成要报给传输层")

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(port.abandonCount, 0, "已建成的流不该再触发就绪超时")
    }

    /// 期间换代次：这一次尝试已经作废，不该放弃新连接。
    func testANewGenerationDisarmsTheReadyTimeout() async throws {
        let (mux, port) = makeMux()
        mux.readyTimeout = 0.05
        port.attachConnection(generation: 1)
        _ = mux.makeStream(FakeBehavior())

        port.attachConnection(generation: 2)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(port.abandonCount, 0, "上一代的超时不该掐这一代")
    }

    // MARK: - S7：令牌同时表达代次与传输

    func testTheAttemptTokenSeparatesGenerationAndTransport() {
        let a = FakePort()
        let b = FakePort()

        XCTAssertEqual(StreamAttempt(generation: 2, connection: a),
                       StreamAttempt(generation: 2, connection: a))
        XCTAssertNotEqual(StreamAttempt(generation: 2, connection: a),
                          StreamAttempt(generation: 3, connection: a),
                          "同一条传输、不同代次 ⇒ 不是同一次尝试")
        XCTAssertNotEqual(StreamAttempt(generation: 2, connection: a),
                          StreamAttempt(generation: 2, connection: b),
                          "同一代次、换了传输 ⇒ 也不是（连接是先关后建）")
    }

    // MARK: - 收帧与换代次

    /// 编号不在表里的帧什么都不做 —— 那是上一条流的尾巴。
    func testFramesForAnUnknownStreamAreIgnored() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()
        _ = try XCTUnwrap(mux.makeStream(behavior))

        mux.receive(frame("someone-else"), raw: Data())

        XCTAssertEqual(behavior.handled, 0, "别的流的帧不进判读器")
        XCTAssertEqual(port.establishCount, 0)
    }

    /// 换代次：每条已开过的流都换新号重开。
    func testReopeningAllGivesEveryStreamAFreshId() throws {
        let (mux, port) = makeMux()
        port.attachConnection(generation: 1)
        let first = try XCTUnwrap(mux.makeStream(FakeBehavior(label: "a")))
        let second = try XCTUnwrap(mux.makeStream(FakeBehavior(label: "b")))
        let firstId = first.id
        let secondId = second.id

        mux.reopenAll()

        XCTAssertNotEqual(first.id, firstId)
        XCTAssertNotEqual(second.id, secondId)
        XCTAssertEqual(port.sent.count, 4, "两条 open + 换代次后两条新 open")
        XCTAssertEqual(port.abandonCount, 0, "换代次不是放弃连接")
    }

    /// 收尾：清空登记，一条帧都不发（线都没了）。
    func testClosingAllSendsNothing() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        _ = try XCTUnwrap(mux.makeStream(FakeBehavior()))
        let sentBefore = port.sent.count

        mux.closeAll()

        XCTAssertEqual(port.sent.count, sentBefore, "收尾不发帧")
        XCTAssertFalse(mux.hasPendingOpening)
    }

}

// MARK: - 由旧判据并入

extension StreamMuxTests {

    /// `.stop` 只收起被拒的那一条 —— 另一条与连接本身都不动。
    ///
    /// 这一条防的是「一条流被拒就把同一条连接上的另一条一起拽断」：那种错法在只有一条流
    /// 时看不出区别，而事件流与会话流是同时活着的。
    func testATerminalRefusalStopsOnlyThatStream() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let refusing = FakeBehavior(label: "a")
        refusing.verdict = { _ in StreamReply(next: .stop) }
        let survivor = FakeBehavior(label: "b")
        let stopped = try XCTUnwrap(mux.makeStream(refusing))
        let alive = try XCTUnwrap(mux.makeStream(survivor))

        mux.receive(frame(stopped.id), raw: Data())

        XCTAssertFalse(mux.isWaitingToRetry(stopped), "终态不排退避")
        XCTAssertEqual(port.abandonCount, 0, "更不能放弃整条连接")

        mux.receive(frame(alive.id), raw: Data())
        XCTAssertEqual(survivor.handled, 1, "另一条流照常工作")
    }

    /// 服务端正常收尾 ⇒ 同一条连接上换号重开（连接不重建）。
    func testAnEndReopensThatStreamWithAFreshId() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(next: .reopen) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let oldId = stream.id

        mux.receive(frame(oldId), raw: Data())

        XCTAssertNotEqual(stream.id, oldId, "收尾是「这条流不在了」，换号重开")
        XCTAssertEqual(port.sent.count, 3, "open(旧) + cancel(旧) + open(新)")
        XCTAssertTrue(port.sent.last?.contains(stream.id) == true, "立刻发出去，不等退避")
    }

    /// 退避期间用户按了「重试」：取消排着的那一拍，立刻开。
    ///
    /// 不取消的话用户会看到「按了没反应」—— 那一拍要到点才发，而它发的是同一件事。
    func testRestartingDuringBackoffOpensImmediately() throws {
        let (mux, port) = makeMux()
        port.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(next: .retry) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        mux.receive(frame(stream.id), raw: Data())
        XCTAssertTrue(mux.isWaitingToRetry(stream), "先确认有一拍排着")
        let sentBefore = port.sent.count

        stream.restart()

        XCTAssertFalse(mux.isWaitingToRetry(stream), "这一拍被取代了")
        XCTAssertEqual(port.sent.count, sentBefore + 2, "cancel(旧) + 立刻 open(新)")
    }

    /// 退避曲线：指数爬升、抖动落在上限的 50–100%、封顶 10 秒。
    ///
    /// 三个抽样点覆盖三种形态，不是三个例子 —— 爬升段、封顶段、抖动两端。
    func testBackoffCurveRisesJittersAndCaps() {
        XCTAssertEqual(StreamBackoff.delayMs(attempt: 1, random: 0), 250, "首拍下限：500 的一半")
        XCTAssertEqual(StreamBackoff.delayMs(attempt: 1, random: 0.999), 499, "首拍上限：接近 500")

        let failed = StreamBackoff.delayMs(attempt: 5, random: 0)
        let failedMax = StreamBackoff.delayMs(attempt: 5, random: 0.999)
        XCTAssertGreaterThan(failed, StreamBackoff.delayMs(attempt: 1, random: 0), "随失败次数爬升")
        XCTAssertEqual(failedMax, 7_996, "第 5 拍上限 8 秒（抖动到 99.95%）")

        XCTAssertEqual(StreamBackoff.delayMs(attempt: 20, random: 0), 5_000, "封顶 10 秒的一半")
        XCTAssertEqual(StreamBackoff.delayMs(attempt: 20, random: 0.999), 9_995, "封顶不越过 10 秒")
    }
}
