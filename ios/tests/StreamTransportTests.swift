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
    func testLivenessTickBranches() {
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
        // `next == limit` 这一格单独钉住：把判死条件写成 `>=` 时，上下两格（1 与 3）都还在
        // 边界两侧不动，只有它会红 —— 少了它，「容错两拍」实际只剩一拍。
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: false, heardFromPeer: false, missed: 1, limit: 2), .probe(missed: 2),
            "第 2 拍连失 2，仍在容错内")
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: false, heardFromPeer: false, missed: 2, limit: 2), .dead)
        // 空闲连接（停在会话列表：一条流都没有）同样要判死：常驻之后大部分时间是这个处境。
        XCTAssertEqual(StreamTransport.livenessTick(
            awaitingOpening: false, heardFromPeer: false, missed: 9, limit: 2), .dead,
            "连失数早已越过上限，不该因为「没有流」而继续 probe")
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

    /// 收到任何一帧都算「对端活着」，但**不等于就绪**：升级之后网关先发 `ready`，
    /// 打开帧的大帧还在路上，此刻置就绪会让心跳立刻激活、再在几拍之后把连接判死。
    func testFramesDoNotMakeTheConnectionReadyOnlyEstablishmentDoes() throws {
        let transport = transport()
        transport.activate()
        XCTAssertEqual(transport.phase, .connecting, "刚发起连接是握手中")

        // 一帧谁都不要的（编号不在流表里）：落进流表后被丢掉，阶段不动。
        let stray = #"{"type":"item","streamId":"nobody","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(stray), generation: 1)
        XCTAssertEqual(transport.phase, .connecting, "收到东西不等于就绪")

        // 某条流报「建成了」：这才是就绪。
        transport.didEstablish()
        XCTAssertEqual(transport.phase, .ready, "建成即就绪")

        // 收尾：另一条用例也在连同一个端点，留下的退避循环会跨用例写日志、抢断言。
        transport.deactivate()
    }

    // MARK: - U4：帧按编号归流

    /// 编号在表里就交给那条流，不在就丢弃 —— 「归谁」只由编号决定。
    ///
    /// 守的是「剩下的这一条路还在」：协议里的每个帧都有编号，收货人只有一个。
    func testFramesReachOnlyTheStreamTheirIdNames() throws {
        let transport = transport()
        let behavior = Behavior()
        let other = Behavior()
        let stream = try XCTUnwrap(transport.mux.makeStream(behavior))
        _ = try XCTUnwrap(transport.mux.makeStream(other))

        let mine = #"{"type":"item","streamId":"\#(stream.id)","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(mine), generation: 1)
        XCTAssertEqual(behavior.handled, 1, "编号在表里：交给那条流")

        let stranger = #"{"type":"item","streamId":"not-in-the-table","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(stranger), generation: 1)
        XCTAssertEqual(behavior.handled, 1, "编号不在表里：谁都收不到")
        XCTAssertEqual(other.handled, 0, "更不会转给别的流")
        transport.deactivate()
    }

    // MARK: - U2：坏帧不带走连接

    func testAnUnparsableFrameLeavesTheConnectionAlive() {
        let transport = transport()
        transport.activate()
        transport.didEstablish()

        transport.handleMessage(.string("not json at all"), generation: 1)

        XCTAssertEqual(transport.phase, .ready, "解不出的帧不是消息，不该改阶段")
        XCTAssertTrue(transport.sentFrames.isEmpty, "更不该因此发任何帧")
        transport.deactivate()
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

// MARK: - 由旧判据并入

extension StreamTransportTests {

    /// 一条流都没有也要连 —— 「常驻」的字面含义就是这句。
    ///
    /// 停在会话列表时正是这个处境：没有流，连接仍在；也正因为如此，半开连接才会被发现。
    func testTheConnectionIsResidentWithoutAnyStream() {
        var handshakes = 0
        let transport = StreamTransport()
        transport.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        transport.authorizationProvider = { "ticket" }
        transport.sessionProvider = {
            handshakes += 1
            return .shared
        }

        transport.activate()

        XCTAssertEqual(handshakes, 1, "没有登记任何流也该连")
        XCTAssertEqual(transport.sentFrames, [], "没有流就没有开流帧可发")

        transport.deactivate()
        XCTAssertEqual(transport.phase, .idle, "收掉之后没有连接，也没有排定的重试")
    }

    /// 在已连接上开第二条流：阶段不闪回「连接中」。
    ///
    /// 阶段的含义是「这条连接走到哪一步」，与登记了几条流无关。
    func testOpeningASecondStreamKeepsThePhase() throws {
        let transport = transport()
        transport.activate()
        transport.didEstablish()
        XCTAssertEqual(transport.phase, .ready)

        _ = try XCTUnwrap(transport.mux.makeStream(Behavior()))
        _ = try XCTUnwrap(transport.mux.makeStream(Behavior()))

        XCTAssertEqual(transport.phase, .ready, "开流不改阶段")
        // 正控：有连接时造流真的发 open。这一组其余各处都断言 `sentFrames` **为空**，
        // 而「send 根本不记账」会让那几条断言一起变成永远为真。
        XCTAssertEqual(transport.sentFrames.count, 2, "两条流就是两条 open")
        transport.deactivate()
    }

    /// 单帧接收上限必须是网关承诺上界的两倍：系统默认 1 MiB 正是「某个会话打不开」的成因。
    func testTheFrameCeilingIsTwiceTheGatewayCap() {
        XCTAssertEqual(StreamTransport.maximumMessageSize, 8 * 1024 * 1024)
    }

    /// 没有票 → 去换；换到了立刻重连（跳过这一轮退避），换不到且不会自愈就停。
    ///
    /// 三种结果三种走向，不能合并：退避里对着「不会自己好」无限重试是每 10 秒一次、
    /// 静默、永不收敛；而把「网络不通」说成「未配对」会让人去查一件没发生的事。
    func testTicketRenewalDecidesTheNextStep() async throws {
        // ① 换到：立刻重连，跳过退避。
        let renewed = transport()
        var handshakes = 0
        renewed.authorizationProvider = { nil }
        renewed.sessionProvider = { handshakes += 1; return .shared }
        renewed.ticketRenewer = { .granted("fresh") }
        renewed.activate()
        XCTAssertEqual(handshakes, 0, "没有票先不握手")
        try await Task.sleep(nanoseconds: 150_000_000)
        // 换到的票要经 `authorizationProvider` 再取一次 —— 这里换的是同一份闭包，
        // 所以第二问必须拿得到票，否则它只会再等一轮。
        renewed.authorizationProvider = { "fresh" }
        renewed.reconnectNow()
        XCTAssertEqual(handshakes, 1, "换到票之后立刻握手")
        renewed.deactivate()

        // ② 拿不到且不会自愈：停，不再排重试。
        let hopeless = transport()
        hopeless.authorizationProvider = { nil }
        hopeless.ticketRenewer = { .unavailable }
        hopeless.activate()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(hopeless.phase, .idle, "不会自愈就不空转")
        hopeless.deactivate()
    }
}
