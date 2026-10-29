/**
 * 流表的**流级**行为：编号、开与关、换号重开、按流退避、开流超时、建成集合。
 *
 * 这一组判据全部落在 `StreamMux` + 一个假端口上，**不需要 socket、不碰 URLSession** ——
 * 「流层能脱离传输被完整断言」这件事由它们的存在本身证明。
 *
 * 为什么值得单独断言：这些事**不会编译失败**。编号复用了、注销关错了流、退避到点重发了
 * 同一个号、开流超时把已经建成的流判成没成 —— 四种都表现为屏幕上的偶然
 *（「切会话后停在正在同步」「旧会话的内容闪一下」「连着却突然断」），真机看得见但说不清。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class StreamMuxTests: XCTestCase {

    // MARK: - 替身

    /// 传输层的替身：只记账，不做判定。
    /// WebSocket 层的替身：只记账，不做判定。
    private final class FakeChannel: Channel {
        var sent: [String] = []
        var ensureCount = 0
        var attempt: StreamAttempt?
        /// 连接层发出的两个事实 —— 由 `attach` 订阅，测试里手动触发。
        var onStopped: (() -> Void)?
        var onGenerationChange: (() -> Void)?

        /// 假装已经有一条连接（第 `generation` 代）。令牌的身份用本对象自己。
        func attachConnection(generation: Int = 1) {
            attempt = StreamAttempt(generation: generation, connection: self)
        }

        func send(_ text: String) { sent.append(text) }
        func ensureConnected() { ensureCount += 1 }
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
            if buildFails { throw RpcClientError.malformedResponse(detail: "test") }
            built.append(id)
            return #"{"type":"open","streamId":"\#(id)"}"#
        }

        func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply {
            handled += 1
            return verdict(envelope)
        }
    }

    private func makeMux() -> (StreamMux, FakeChannel) {
        let channel = FakeChannel()
        let mux = StreamMux()
        mux.attach(channel: channel)
        return (mux, channel)
    }

    private func frame(_ id: StreamId) -> MuxServerEnvelope {
        MuxServerEnvelope(type: "item", streamId: id, payload: nil)
    }

    // MARK: - S2：两个反应由事件驱动

    /// 停用事件 ⇒ 清表；换代次事件 ⇒ 每条开过的流换号。
    ///
    /// 这两件事从前由连接层直接调 `closeAll` / `reopenAll` 完成。改成事件之后，这一条守的是
    /// **流层订阅了**：只把连接层的调用删掉、事件发了没人听，行为会静默消失而别的判据仍绿。
    func testStopAndGenerationEventsDriveTheTable() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection(generation: 1)
        let behavior = FakeBehavior()
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let firstId = stream.id

        // 「表里有没有这一条」按真实路径问：喂一帧给它，看判读器收到没有。
        mux.receive(frame(stream.id), raw: Data())
        XCTAssertEqual(behavior.handled, 1, "正控：先确认表里有一条")

        channel.onGenerationChange?()
        XCTAssertNotEqual(stream.id, firstId, "换代次 ⇒ 这条流换号重开")

        channel.onStopped?()
        mux.receive(frame(stream.id), raw: Data())
        XCTAssertEqual(behavior.handled, 1, "停用 ⇒ 表已清空，帧不再进判读器")
    }

    // MARK: - S1：造流 = 一个编号 + 一条 open

    func testMakingAStreamMintsOneIdAndSendsOneOpen() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()

        let stream = try XCTUnwrap(mux.makeStream(FakeBehavior()))

        XCTAssertFalse(stream.id.isEmpty, "编号由流表造，不能为空")
        XCTAssertEqual(channel.sent.count, 1, "造一条流恰好发一条 open")
        XCTAssertTrue(channel.sent[0].contains(stream.id), "发出去的文本里是刚造的那个号")
        XCTAssertEqual(channel.ensureCount, 0, "已有连接时不该再要一条")
    }

    /// 没有连接时：登记好、**不发帧**，而是让传输层去建一条。
    func testMakingAStreamWithoutAConnectionAsksForOne() throws {
        let (mux, channel) = makeMux()

        let stream = try XCTUnwrap(mux.makeStream(FakeBehavior()))

        XCTAssertEqual(channel.sent, [], "没有连接就一个字节都不发")
        XCTAssertEqual(channel.ensureCount, 1, "登记之后要让传输层建一条")
        XCTAssertFalse(stream.id.isEmpty)
    }

    // MARK: - S2：对象化之后 makeStream 不幂等

    /// 同一业务造两次就是两条流、两个号。流以对象自身为身份，所以「重复调用安全」
    /// 不再成立 —— **业务要负责只造一次**（各自的一次性闸）。
    func testMakingTwiceYieldsTwoStreamsWithDifferentIds() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()

        let first = try XCTUnwrap(mux.makeStream(behavior))
        let second = try XCTUnwrap(mux.makeStream(behavior))

        XCTAssertNotEqual(first.id, second.id, "两次造流必须是两个号")
        XCTAssertEqual(channel.sent.count, 2, "两条流各发一条 open")
    }

    /// `build` 抛错：不造流、不发帧 —— 开一条注定看不懂的流只会让屏幕停在「正在同步…」。
    func testAFailingBuildMakesNoStream() {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()
        behavior.buildFails = true

        XCTAssertNil(mux.makeStream(behavior), "编不出开流文本时不造流")
        XCTAssertEqual(channel.sent, [])
    }

    // MARK: - S3：注销只碰自己、幂等

    func testClosingSendsOneCancelForItsOwnIdAndIsIdempotent() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let first = try XCTUnwrap(mux.makeStream(FakeBehavior(label: "a")))
        let secondBehavior = FakeBehavior(label: "b")
        let second = try XCTUnwrap(mux.makeStream(secondBehavior))

        mux.close(first)
        XCTAssertEqual(channel.sent.count, 3, "两条 open + 一条 cancel")
        XCTAssertTrue(channel.sent.last?.contains(first.id) == true, "取消帧指向自己那个号")
        XCTAssertTrue(channel.sent.last?.contains(second.id) == false, "不碰另一条流")

        mux.close(first)
        XCTAssertEqual(channel.sent.count, 3, "关第二次什么都不发")

        // 另一条流还在：它的帧仍然进判读器。
        mux.receive(frame(second.id), raw: Data())
        XCTAssertEqual(secondBehavior.handled, 1, "另一条流照常收帧")
    }

    // MARK: - S4：重开先取消旧号、再换新号

    func testRestartCancelsTheOldIdThenOpensWithAFreshOne() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let oldId = stream.id

        stream.restart()

        XCTAssertNotEqual(stream.id, oldId, "重开必须换号")
        XCTAssertEqual(channel.sent.count, 3, "open(旧) + cancel(旧) + open(新)")
        XCTAssertTrue(channel.sent[1].contains(oldId), "第二条是取消旧号")
        XCTAssertTrue(channel.sent[2].contains(stream.id), "第三条用新号开出去")
        XCTAssertEqual(behavior.built, [oldId, stream.id], "文本按新号重拼过一次")
    }

    // MARK: - S5：被拒按自己的退避重试

    func testARefusalRenumbersImmediatelyAndSchedulesARetry() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(next: .retry) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let oldId = stream.id

        mux.receive(frame(oldId), raw: Data())

        XCTAssertNotEqual(stream.id, oldId, "被拒之后当场换号（新号等退避到了再发）")
        XCTAssertEqual(channel.sent.count, 2, "open(旧) + cancel(旧)；新号还没有发出去")
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

    // MARK: - S6：开流超时的判据是「还是这一次尝试」

    /// 一条流等不到开口帧 → **只重开这条流**：换号、发 cancel、排自己的退避，别的流与连接都不动。
    ///
    /// 三条断言各挡一种退化，缺一条就有一种活下来：
    /// 1. 换号 —— 不重开时这条流永远等不到开口帧；
    /// 2. 不向传输层要连接（`ensureCount`）—— 「整条连接重来」不会让换号与 cancel 变红；
    /// 3. 另一条流原样 —— 「对全体流逐条重开」也不会让前两条变红，这条才挡得住。
    func testTheOpeningTimeoutReopensThatStreamOnly() async throws {
        let (mux, channel) = makeMux()
        mux.openTimeout = 0.05
        channel.attachConnection(generation: 3)
        let stream = try XCTUnwrap(mux.makeStream(FakeBehavior()))

        // 证人流：先让它建成（建成即撤防它的开流超时），于是这一轮只有被测那条流会超时。
        let witnessBehavior = FakeBehavior(label: "witness")
        witnessBehavior.verdict = { _ in StreamReply(establishes: true) }
        let witness = try XCTUnwrap(mux.makeStream(witnessBehavior))
        mux.receive(frame(witness.id), raw: Data())

        let firstId = stream.id
        let witnessId = witness.id
        let sentBefore = channel.sent.count
        let afterTimeout = 0.15

        try await Task.sleep(nanoseconds: UInt64(afterTimeout * 1_000_000_000))

        let sentSince = channel.sent.dropFirst(sentBefore)
        XCTAssertNotEqual(stream.id, firstId, "超时后这条流换了号")
        XCTAssertTrue(sentSince.contains { $0.contains(firstId) }, "旧号要发 cancel")
        XCTAssertEqual(channel.ensureCount, 0, "超时不该向传输层要连接 —— 那等于整条连接重来")
        XCTAssertTrue(mux.isWaitingToRetry(stream), "排的是这条流自己的退避，不是立刻重开")
        XCTAssertEqual(witness.id, witnessId, "另一条流不该被换号")
        XCTAssertFalse(sentSince.contains { $0.contains(witnessId) },
                       "另一条流既不 cancel 也不重开")
    }

    /// 开流超时的值是算出来的，不是抄来的。
    ///
    /// 它必须盖住「最慢链路上传完承诺上界」所需的时间：抄上游 15s 的那版在真机上活不过
    /// 1.25 MB 的打开帧。判据钉的是这个关系，不是某个魔法数 —— 改小它会当场红。
    func testTheOpenTimeoutCoversTheSlowestLink() {
        let worstCaseSeconds = Double(4 * 1024 * 1024) / (125 * 1024)   // 4 MiB ÷ 125 KB/s ≈ 33.6s
        let timeout = StreamMux().openTimeout
        XCTAssertGreaterThanOrEqual(timeout, worstCaseSeconds,
                                    "盖不住最慢链路时，大窗口会被自己掐断")
        XCTAssertEqual(timeout, 45, "取值 = 33.6s + 建连 ~2s，取整到 45s")
    }

    /// 期间建成了：不再重开。
    func testAnEstablishedStreamDisarmsTheOpenTimeout() async throws {
        let (mux, channel) = makeMux()
        mux.openTimeout = 0.05
        channel.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(establishes: true) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let establishedId = stream.id

        mux.receive(frame(stream.id), raw: Data())

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stream.id, establishedId, "已建成的流不该再触发开流超时")
    }

    /// 期间换代次：这一次尝试已经作废，不该动新连接上的流。
    func testANewGenerationDisarmsTheOpenTimeout() async throws {
        let (mux, channel) = makeMux()
        mux.openTimeout = 0.05
        channel.attachConnection(generation: 1)
        let stream = try XCTUnwrap(mux.makeStream(FakeBehavior()))
        let originalId = stream.id

        channel.attachConnection(generation: 2)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(stream.id, originalId, "上一代的超时不该动这一代")
    }

    // MARK: - S7：令牌同时表达代次与传输

    func testTheAttemptTokenSeparatesGenerationAndTransport() {
        let a = FakeChannel()
        let b = FakeChannel()

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
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()
        _ = try XCTUnwrap(mux.makeStream(behavior))

        mux.receive(frame("someone-else"), raw: Data())

        XCTAssertEqual(behavior.handled, 0, "别的流的帧不进判读器")
    }

    /// 换代次：每条已开过的流都换新号重开。
    func testReopeningAllGivesEveryStreamAFreshId() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection(generation: 1)
        let first = try XCTUnwrap(mux.makeStream(FakeBehavior(label: "a")))
        let second = try XCTUnwrap(mux.makeStream(FakeBehavior(label: "b")))
        let firstId = first.id
        let secondId = second.id

        channel.onGenerationChange?()

        XCTAssertNotEqual(first.id, firstId)
        XCTAssertNotEqual(second.id, secondId)
        XCTAssertEqual(channel.sent.count, 4, "两条 open + 换代次后两条新 open")
    }

    /// 收尾：清空登记，一条帧都不发（线都没了）。
    func testClosingAllSendsNothing() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        _ = try XCTUnwrap(mux.makeStream(FakeBehavior()))
        let sentBefore = channel.sent.count

        channel.onStopped?()

        XCTAssertEqual(channel.sent.count, sentBefore, "收尾不发帧")
    }

    /// `.stop` 只收起被拒的那一条 —— 另一条与连接本身都不动。
    ///
    /// 这一条防的是「一条流被拒就把同一条连接上的另一条一起拽断」：那种错法在只有一条流
    /// 时看不出区别，而事件流与会话流是同时活着的。
    func testATerminalRefusalStopsOnlyThatStream() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let refusing = FakeBehavior(label: "a")
        refusing.verdict = { _ in StreamReply(next: .stop) }
        let survivor = FakeBehavior(label: "b")
        let stopped = try XCTUnwrap(mux.makeStream(refusing))
        let alive = try XCTUnwrap(mux.makeStream(survivor))

        mux.receive(frame(stopped.id), raw: Data())

        XCTAssertFalse(mux.isWaitingToRetry(stopped), "终态不排退避")

        mux.receive(frame(alive.id), raw: Data())
        XCTAssertEqual(survivor.handled, 1, "另一条流照常工作")
    }

    /// 服务端正常收尾 ⇒ 同一条连接上换号重开（连接不重建）。
    func testAnEndReopensThatStreamWithAFreshId() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(next: .reopen) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        let oldId = stream.id

        mux.receive(frame(oldId), raw: Data())

        XCTAssertNotEqual(stream.id, oldId, "收尾是「这条流不在了」，换号重开")
        XCTAssertEqual(channel.sent.count, 3, "open(旧) + cancel(旧) + open(新)")
        XCTAssertTrue(channel.sent.last?.contains(stream.id) == true, "立刻发出去，不等退避")
    }

    /// 退避期间用户按了「重试」：取消排着的那一拍，立刻开。
    ///
    /// 不取消的话用户会看到「按了没反应」—— 那一拍要到点才发，而它发的是同一件事。
    func testRestartingDuringBackoffOpensImmediately() throws {
        let (mux, channel) = makeMux()
        channel.attachConnection()
        let behavior = FakeBehavior()
        behavior.verdict = { _ in StreamReply(next: .retry) }
        let stream = try XCTUnwrap(mux.makeStream(behavior))
        mux.receive(frame(stream.id), raw: Data())
        XCTAssertTrue(mux.isWaitingToRetry(stream), "先确认有一拍排着")
        let sentBefore = channel.sent.count

        stream.restart()

        XCTAssertFalse(mux.isWaitingToRetry(stream), "这一拍被取代了")
        XCTAssertEqual(channel.sent.count, sentBefore + 2, "cancel(旧) + 立刻 open(新)")
    }

    /// 退避曲线：指数爬升、抖动落在上限的 50–100%、封顶 10 秒。
    ///
    /// 三个抽样点覆盖三种形态，不是三个例子 —— 爬升段、封顶段、抖动两端。
    func testBackoffCurveRisesJittersAndCaps() {
        XCTAssertEqual(Backoff.delayMs(attempt: 1, random: 0), 250, "首拍下限：500 的一半")
        XCTAssertEqual(Backoff.delayMs(attempt: 1, random: 0.999), 499, "首拍上限：接近 500")

        let failed = Backoff.delayMs(attempt: 5, random: 0)
        let failedMax = Backoff.delayMs(attempt: 5, random: 0.999)
        XCTAssertGreaterThan(failed, Backoff.delayMs(attempt: 1, random: 0), "随失败次数爬升")
        XCTAssertEqual(failedMax, 7_996, "第 5 拍上限 8 秒（抖动到 99.95%）")

        XCTAssertEqual(Backoff.delayMs(attempt: 20, random: 0), 5_000, "封顶 10 秒的一半")
        XCTAssertEqual(Backoff.delayMs(attempt: 20, random: 0.999), 9_995, "封顶不越过 10 秒")
    }
}
