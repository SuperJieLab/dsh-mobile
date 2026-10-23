/**
 * 传输层的判据：心跳判定、迟到的回调、坏帧不带走连接、无编号帧的去处、就绪只由建成触发。
 *
 * 这一组用**真的 `StreamTransport`** 加一个连不上的端点（`127.0.0.1:1`）来验编排，
 * 纯判定（心跳、迟到回调）直接调静态函数。不构造假 socket：`URLSessionWebSocketTask`
 * 没有可替换的公开接口，为它造替身只会测到替身。
 *
 * 为什么值得单独断言：这些事都不会编译失败。心跳判早了表现为「传大帧时莫名断线」，
 * 判晚了表现为「半死连接永不发现」，`.ready` 判早了表现为「刚连上就断」——
 * 三种都只有真机才露出来，而真机上分不清是哪一处判错。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class StreamTransportTests: XCTestCase {

    /// 连不上的端点：握手会真发起（必定失败），但**发帧是同步的**，断言紧跟在动作之后。
    ///
    /// ⚠️ 握手失败之后传输层会按退避换届次（250–500ms 一拍），每一代都重开所有流。
    /// 所以只写不跨越退避窗口的断言；要等编排跑起来的地方显式等够一拍。
    private func transport() -> StreamTransport {
        let transport = StreamTransport()
        transport.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        transport.authorizationProvider = { "ticket" }
        transport.sessionProvider = { .shared }
        return transport
    }

    /// 一个只记事的收货人。
    private final class Sink: UnscopedFrameSink {
        var frames: [MuxServerEnvelope] = []
        func accept(_ frame: MuxServerEnvelope) { frames.append(frame) }
    }

    /// 一个只记事的判读：收到帧就算一条，答复可配。
    private final class Behavior: StreamBehavior {
        let label = "s1"
        var handled = 0
        func build(_ id: StreamId) throws -> String {
            #"{"type":"open","streamId":"\#(id)"}"#
        }
        func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply {
            handled += 1
            return StreamReply()
        }
    }

    // MARK: - U1：心跳的一个节拍

    /// 规则两句话：**有流在等打开帧时不判死；本拍收到过对端的东西就归零。**
    ///
    /// 第一条防的是「传大帧时误杀」：网关先发对账帧、打开帧的大帧占住整条 TCP，
    /// 我们的 pong 排在它后面，一拍也到不了。
    func testLivenessTickFourBranches() {
        // 有流在等打开帧：无论收到过什么、连失多少，都继续探活且归零。
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: true, heardFromPeer: false, missed: 2, limit: 2), .probe(missed: 0))
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: true, heardFromPeer: true, missed: 1, limit: 2), .probe(missed: 0))

        // 没在等：收到过东西 ⇒ 归零。
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: false, heardFromPeer: true, missed: 2, limit: 2), .probe(missed: 0))

        // 没在等、也没收到：连失数累加，到上限之上判死。
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: false, heardFromPeer: false, missed: 0, limit: 2), .probe(missed: 1))
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: false, heardFromPeer: false, missed: 2, limit: 2), .dead)
    }

    // MARK: - U5：迟到的回调该不该起作用

    /// 代次与传输**双重相等**才算「本代当前的那条连接」。松一格，一个被取代的发送回调
    /// 就会把刚建好的连接掐掉、再排一次重连 —— 每 2 秒一转、永不恢复。
    func testLateCallbacksOnlyApplyToTheSameGenerationAndTransport() {
        XCTAssertTrue(StreamTransport.callbackApplies(
            generation: 3, current: 3, sameTask: true))
        XCTAssertFalse(StreamTransport.callbackApplies(
            generation: 2, current: 3, sameTask: true), "旧代次的回调不作数")
        XCTAssertFalse(StreamTransport.callbackApplies(
            generation: 3, current: 3, sameTask: false), "同代但换了传输，也不作数")
        XCTAssertFalse(StreamTransport.callbackApplies(
            generation: 2, current: 3, sameTask: false))
    }

    // MARK: - U7：`.ready` 只由「某条流建成」触发

    /// 收到任何一帧都算「对端活着」，但**不等于就绪**：升级之后网关先发对账帧，
    /// 打开帧的大帧还在路上，此刻置就绪会让心跳立刻激活、再在几拍之后把连接判死。
    func testFramesDoNotMakeTheConnectionReadyOnlyEstablishmentDoes() throws {
        let transport = transport()
        let sink = Sink()
        transport.unscopedSink = sink
        transport.activate()
        XCTAssertEqual(transport.phase, .connecting, "刚发起连接是握手中")

        // 一帧无编号的（审批对账帧就是这种）：进收货人，阶段不动。
        let ledger = #"{"type":"approval","payload":{"kind":"sync","eventIds":[]}}"#
        transport.handleMessage(.string(ledger), generation: 1)
        XCTAssertEqual(sink.frames.count, 1, "无编号帧交给收货人")
        XCTAssertEqual(transport.phase, .connecting, "收到东西不等于就绪")

        // 某条流报「建成了」：这才是就绪。
        transport.didEstablish("s1")
        XCTAssertEqual(transport.phase, .ready, "建成即就绪")
    }

    // MARK: - U4：无编号帧只到收货人

    /// 没有编号的帧不属于任何流：它不进流表，也不被某条流代收。
    /// 「归谁」若取决于谁先登记，屏幕一关那条流就没了 —— 审批因此永远收不到。
    func testUnscopedFramesReachTheSinkAndNeverAStream() throws {
        let transport = transport()
        let sink = Sink()
        transport.unscopedSink = sink
        let behavior = Behavior()
        let stream = try XCTUnwrap(transport.mux.makeStream(behavior))

        let unscoped = #"{"type":"approval","payload":{"kind":"cancel","eventId":"e1"}}"#
        transport.handleMessage(.string(unscoped), generation: 1)

        XCTAssertEqual(sink.frames.count, 1)
        XCTAssertEqual(behavior.handled, 0, "无编号帧不进任何一条流")

        // 有编号的帧走流表。
        let scoped = #"{"type":"item","streamId":"\#(stream.id)"}"#
        transport.handleMessage(.string(scoped), generation: 1)
        XCTAssertEqual(behavior.handled, 1, "有编号的帧交给那条流")
        XCTAssertEqual(sink.frames.count, 1, "有编号的帧不进收货人")
    }

    // MARK: - U2：坏帧不带走连接

    func testAnUnparsableFrameLeavesTheConnectionAlive() {
        let transport = transport()
        transport.activate()
        transport.didEstablish("s1")

        transport.handleMessage(.string("not json at all"), generation: 1)

        XCTAssertEqual(transport.phase, .ready, "解不出的帧不是消息，不该改阶段")
        XCTAssertTrue(transport.sentFrames.isEmpty, "更不该因此发任何帧")
    }

    // MARK: - U6：退避与代次由传输层自己决定

    /// 连不上时：阶段按 `connecting → waiting(ms) → connecting` 循环，每一代都重新来一遍。
    /// 判据盯的是**观察到两次以上 `.connecting`** —— 每一代握手都置它一次，
    /// 于是「代次在递增」有了一个不依赖内部字段的观测点。
    func testAFailingEndpointKeepsCyclingPhaseWithoutLeavingIdle() async throws {
        let transport = transport()
        var phases: [StreamPhase] = []
        transport.onPhaseChange = { phases.append($0) }

        transport.activate()
        XCTAssertEqual(phases, [.connecting], "一发起就离开 idle")

        // 第一次退避 250–500ms，等够两拍。
        try await Task.sleep(nanoseconds: 900_000_000)

        let connectingCount = phases.filter { $0 == .connecting }.count
        XCTAssertGreaterThanOrEqual(connectingCount, 2, "每一代握手都置 connecting：\(phases)")
        XCTAssertTrue(phases.contains { if case .waiting = $0 { return true }; return false },
                      "失败之后进等待：\(phases)")
        XCTAssertFalse(phases.contains(.ready), "从没建成，不该有 ready")
        XCTAssertFalse(phases.contains(.idle), "排着重试，不该回 idle")

        transport.deactivate()
    }

    /// 没有票不裸连：那一发必定被 401 拒，先去换票。
    func testWithoutATicketNoHandshakeIsAttempted() async throws {
        let transport = StreamTransport()
        var handshakes = 0
        transport.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        transport.authorizationProvider = { nil }
        transport.sessionProvider = {
            handshakes += 1
            return .shared
        }
        transport.activate()

        XCTAssertEqual(handshakes, 0, "没有票就不发握手")
        XCTAssertEqual(transport.sentFrames, [], "也不记账")
        transport.deactivate()
    }
}
