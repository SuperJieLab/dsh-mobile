/**
 * 传输层的判据：心跳判定、迟到的回调、坏帧不带走连接、帧只进流表、收到帧即就绪。
 *
 * 这一组用**真的 `WebSocketConnection`** 加一个连不上的端点（`127.0.0.1:1`）来验编排，
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
final class WebSocketConnectionTests: XCTestCase {

    /// 连不上的端点：握手会真发起（必定失败），但**发帧是同步的**，断言紧跟在动作之后。
    ///
    /// ⚠️ 握手失败之后传输层会按退避换届次（250–500ms 一拍），每一代都重开所有流。
    /// 所以只写不跨越退避窗口的断言；要等编排跑起来的地方显式等够一拍。
    private func transport() -> WebSocketConnection {
        let transport = WebSocketConnection()
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
        func handle(_ frame: InboundFrame) -> StreamReply {
            handled += 1
            return StreamReply()
        }
    }

    /// 等解码头把已投递的帧提交完。
    ///
    /// 按 `inboundBacklog` 判空，不靠固定 `sleep` —— 猜的时长在慢机器上必错。200 ms 上限：
    /// 真排不空说明解码头没在跑，那是缺陷而不是慢。
    private func drain(_ transport: WebSocketConnection) async {
        for _ in 0..<200 {
            if transport.inboundBacklog == 0 { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("解码头 200 ms 内没排空：\(transport.inboundBacklog) 帧还压着")
    }

    // MARK: - U1：心跳的一个节拍

    /// 规则一句话：**本拍收到过对端的东西就归零，否则连失累加，越过窗口那一拍判死。**
    ///
    /// 「传大帧时不误杀」不靠这条规则，靠窗口本身够长（见 U8）。
    func testLivenessTickBranches() {
        // 收到过东西 ⇒ 归零。
        XCTAssertEqual(WebSocketConnection.livenessTick(
            window: 6, heardFromPeer: true, missed: 2), .probe(missed: 0))

        // 没收到：累加，到窗口那一拍判死。6 秒 ÷ 2 秒节拍 = 3 拍。
        XCTAssertEqual(WebSocketConnection.livenessTick(
            window: 6, heardFromPeer: false, missed: 0), .probe(missed: 1))
        // `next == limit` 这一格单独钉住：把判死条件写成 `>=` 时，上下两格都还在边界两侧不动，
        // 只有它会红 —— 少了它，容错就少一拍。
        XCTAssertEqual(WebSocketConnection.livenessTick(
            window: 6, heardFromPeer: false, missed: 1), .probe(missed: 2),
            "第 2 拍连失 2，仍在窗口内")
        XCTAssertEqual(WebSocketConnection.livenessTick(
            window: 6, heardFromPeer: false, missed: 2), .dead, "第 3 拍到点")
        // 空闲连接（停在会话列表：一条流都没有）同样要判死：常驻之后大部分时间是这个处境。
        XCTAssertEqual(WebSocketConnection.livenessTick(
            window: 60, heardFromPeer: false, missed: 29), .dead,
            "60 秒窗口 = 第 30 拍；连失数越界后不该继续 probe")
    }

    // MARK: - U8：判死窗口可注入

    /// 窗口是一个**可拨的量**，不是两个常量的乘积；判死发生在第 `窗口 ÷ 节拍` 拍。
    ///
    /// 为什么必须可拨：大消息传输期间 `receive` 不回调、pong 排在消息之后（实测 4 MiB /
    /// 400 KB/s 下延迟 10 秒以上），窗口必须长到覆盖它；而「长到覆盖」这件事只有把窗口
    /// 拨短才验得了 —— 否则每条判据都要跑满一个真实窗口。
    func testLivenessWindowIsInjectable() {
        XCTAssertEqual(WebSocketConnection.attemptLimit(for: 6), 2, "6 秒 ÷ 2 秒节拍 = 3 拍")
        XCTAssertEqual(WebSocketConnection.attemptLimit(for: 60), 29, "60 秒 ÷ 2 秒节拍 = 30 拍")
        // 非整倍数单独钉住：只钉 6 与 60 的话，把向上取整改成向下取整，那两条都还是绿的。
        XCTAssertEqual(WebSocketConnection.attemptLimit(for: 5), 2, "5 秒 ÷ 2 = 2.5，向上取整 = 3 拍")

        let short = transport()
        XCTAssertEqual(short.livenessWindow, 60, "默认窗口要覆盖慢链路上的最大一帧")
        short.livenessWindow = 6
        XCTAssertEqual(short.livenessStep(), .probe(missed: 1))
        XCTAssertEqual(short.livenessStep(), .probe(missed: 2))
        XCTAssertEqual(short.livenessStep(), .dead, "6 秒窗口 = 第 3 拍判死")

        // 默认值下同一条判定要能等满 30 拍 —— 窗口是被读的那个数，不是写死的 6。
        let long = transport()
        for beat in 1...29 {
            XCTAssertNotEqual(long.livenessStep(), .dead, "第 \(beat) 拍还在窗口内")
        }
        XCTAssertEqual(long.livenessStep(), .dead, "60 秒窗口 = 第 30 拍判死")

        // 证据被这一拍消费掉：收到一帧之后归零，且那一帧不能顺延算到下一拍。
        let reset = transport()
        XCTAssertEqual(reset.livenessStep(), .probe(missed: 1))
        reset.handleMessage(.string(#"{"type":"item","streamId":"nobody","payload":{}}"#),
                            generation: 1)
        XCTAssertEqual(reset.livenessStep(), .probe(missed: 0), "这一拍收到过东西就归零")
        XCTAssertFalse(reset.heardFromPeer, "证据被这一拍消费掉了")
        XCTAssertEqual(reset.livenessStep(), .probe(missed: 1), "下一拍从零重新计")

        // 两个时刻必须错开：开流超时要先把「只重开这一条」做完，判死窗口才轮到。
        // 同值时两者同刻触发，行为退化成「整条连接重连」—— 而这只差一个数字，编译不会报。
        // 余量（现在 15 秒）的宽窄靠代码评审，断言只钉方向。
        XCTAssertGreaterThan(long.livenessWindow, StreamMux().openTimeout,
                             "判死窗口必须长于流层的开流超时")
    }

    // MARK: - U5：迟到的回调该不该起作用

    /// 代次与传输**双重相等**才算「本代当前的那条连接」。松一格，一个被取代的发送回调
    /// 就会把刚建好的连接掐掉、再排一次重连 —— 每 2 秒一转、永不恢复。
    func testLateCallbacksOnlyApplyToTheSameGenerationAndTransport() {
        XCTAssertTrue(WebSocketConnection.callbackApplies(
            generation: 3, current: 3, sameTask: true))
        XCTAssertFalse(WebSocketConnection.callbackApplies(
            generation: 2, current: 3, sameTask: true), "旧代次的回调不作数")
        XCTAssertFalse(WebSocketConnection.callbackApplies(
            generation: 3, current: 3, sameTask: false), "同代但换了传输，也不作数")
        XCTAssertFalse(WebSocketConnection.callbackApplies(
            generation: 2, current: 3, sameTask: false))
    }

    // MARK: - U7：收到一帧即就绪

    /// 收到任何一条可解析的帧，就算这一代连接已经通了 —— 同时它就是心跳要的证据。
    ///
    /// 「就绪」与「还活着」在本层是同一个信号：判定两者的依据都只能是「收到东西」。
    /// 大消息期间不误杀靠的是窗口够长（U8），不是靠把就绪推后。
    func testAnyParsableFrameMakesTheConnectionReady() async throws {
        let transport = transport()
        transport.activate()
        XCTAssertEqual(transport.phase, .connecting, "刚发起连接是握手中")
        XCTAssertFalse(transport.heardFromPeer, "还没收到过任何东西")

        // 一帧谁都不要的（编号不在流表里）也算：它证明这一代连接真的通了。
        let stray = #"{"type":"item","streamId":"nobody","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(stray), generation: 1)
        // 证据记账是同步的，就绪要等解码头提交 —— 两者不是同一个时刻，这一条把它钉住。
        XCTAssertTrue(transport.heardFromPeer, "同一帧也是心跳要的证据 —— 两个判据同一个来源")
        await drain(transport)
        XCTAssertEqual(transport.phase, .ready, "收到一帧就是通了")

        // 收尾：另一条用例也在连同一个端点，留下的退避循环会跨用例写日志、抢断言。
        transport.deactivate()
    }

    // MARK: - 顺序

    /// 记下每一帧的 `seq`，用来断言到达顺序。
    private final class OrderBehavior: StreamBehavior {
        let label = "order"
        var seen: [Int] = []
        func build(_ id: StreamId) throws -> String {
            #"{"type":"open","streamId":"\#(id)"}"#
        }
        func handle(_ frame: InboundFrame) -> StreamReply {
            if case .item(.connectionItem(let json)) = frame.payload,
               let seq = json["seq"]?.int {
                seen.append(seq)
            }
            return StreamReply()
        }
    }

    /// 连投 20 帧，接帧那一侧收到的顺序必须与投递一致。
    ///
    /// 解码头是**单消费者**，这条守住它别被改成「每帧一个任务」—— 那种写法下顺序取决于
    /// 谁先跑完，而事件流靠 `seq` 排重、靠顺序落状态，乱序不会崩、只会让界面对不上。
    ///
    /// ⚠️ 这条的红是概率性的：变异成并发后有时仍然有序。它的价值在「每次都跑一遍」，
    /// 不在「一次就抓住」。
    func testFramesArriveInTheOrderTheyWereReceived() async throws {
        let (transport, streams) = transportWithStreams()
        let behavior = OrderBehavior()
        let stream = try XCTUnwrap(streams.makeStream(behavior))

        for seq in 1...20 {
            let text = "{\"type\":\"item\",\"streamId\":\"\(stream.id)\","
                + "\"payload\":{\"kind\":\"emit\",\"event\":\"x\",\"seq\":\(seq)}}"
            transport.handleMessage(.string(text), generation: 1)
        }
        await drain(transport)

        XCTAssertEqual(behavior.seen, Array(1...20), "帧序必须与投递一致（单消费者）")
        transport.deactivate()
    }

    /// 连不上的端点 + 一张接好的流表。
    ///
    /// 连接层不再持有流表，两个模板要由外面接起来 —— 这一组用例就是那个「外面」，
    /// 与 `LongConnection` 的接线同形（`attach` + `onFrame`）。少了任何一条，帧的归属与
    /// 开流记账都观察不到。
    private func transportWithStreams() -> (WebSocketConnection, StreamMux) {
        let transport = transport()
        let streams = StreamMux()
        streams.attach(channel: transport)
        transport.onFrame = { [weak streams] frame in
            streams?.receive(frame)
        }
        return (transport, streams)
    }

    // MARK: - U4：帧按编号归流

    /// 编号在表里就交给那条流，不在就丢弃 —— 「归谁」只由编号决定。
    ///
    /// 守的是「剩下的这一条路还在」：协议里的每个帧都有编号，收货人只有一个。
    func testFramesReachOnlyTheStreamTheirIdNames() async throws {
        let (transport, streams) = transportWithStreams()
        let behavior = Behavior()
        let other = Behavior()
        let stream = try XCTUnwrap(streams.makeStream(behavior))
        _ = try XCTUnwrap(streams.makeStream(other))

        let mine = #"{"type":"item","streamId":"\#(stream.id)","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(mine), generation: 1)
        await drain(transport)
        XCTAssertEqual(behavior.handled, 1, "编号在表里：交给那条流")

        let stranger = #"{"type":"item","streamId":"not-in-the-table","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(stranger), generation: 1)
        await drain(transport)
        XCTAssertEqual(behavior.handled, 1, "编号不在表里：谁都收不到")
        XCTAssertEqual(other.handled, 0, "更不会转给别的流")
        transport.deactivate()
    }

    // MARK: - U2：坏帧不带走连接

    func testAnUnparsableFrameLeavesTheConnectionAlive() async {
        let transport = transport()
        transport.activate()
        // 先让它通了，再喂一条坏帧。
        let ok = #"{"type":"item","streamId":"nobody","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(ok), generation: 1)
        await drain(transport)
        XCTAssertEqual(transport.phase, .ready)

        transport.handleMessage(.string("not json at all"), generation: 1)
        await drain(transport)

        XCTAssertEqual(transport.phase, .ready, "解不出的帧不是消息，不该改阶段")
        XCTAssertTrue(transport.sentFrames.isEmpty, "更不该因此发任何帧")
        transport.deactivate()
    }

    // MARK: - 等组网：不自己退避

    /// 没有可连的地址时停在「等组网」，**不进退避、不烧退避档位**。
    ///
    /// 两件事分别会坏，所以两条都断言：
    /// ① 若它仍走 `scheduleReconnect`，等待期间会出现 `.waiting` 与第二次 `.connecting`
    ///    —— 症状是组网真就绪时第一发就要等 10 秒（档位已被空转烧到上限）；
    /// ② 若它永不醒，组网就绪后界面永远停在「等组网」—— 症状是组网明明好了却连不上。
    func testNoEndpointWaitsForMeshInsteadOfBackingOff() async throws {
        let waiting = WebSocketConnection()
        var endpoint: URL?
        waiting.baseURLProvider = { endpoint }
        waiting.authorizationProvider = { "ticket" }
        waiting.sessionProvider = { .shared }
        var phases: [ConnectionPhase] = []
        var transitions: [(ConnectionPhase?, ConnectionPhase)] = []
        waiting.onPhaseChanged = { old, new in
            transitions.append((old, new))
            phases.append(new)
        }

        waiting.activate()
        XCTAssertEqual(phases, [.awaitingMesh], "没有地址就该说「等组网」，而不是「连接中」")
        XCTAssertEqual(transitions.first?.0, .idle,
                       "首参是变化前的那一格 —— 只传新值等于让每个接收方自己记上一次")

        // 等够一拍退避的时间窗：若它偷偷退避，这段时间足够出现 waiting 与下一代 connecting。
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(phases, [.awaitingMesh], "等组网期间不该自己退避：\(phases)")

        // 组网就绪：地址出现，根部观察组网阶段之后调 reconnectNow 把它叫醒。
        endpoint = URL(string: "http://127.0.0.1:1")
        waiting.reconnectNow(reason: "mesh-ready")
        XCTAssertEqual(phases.last, .connecting, "叫醒之后立刻握手：\(phases)")
        waiting.deactivate()
    }

    /// 没有地址时 `reconnectNow` **什么都不做** —— 尤其不该把排着的那一拍退避悄悄取消掉。
    ///
    /// 契约是「跳过退避立刻重连」，而这句话的前提是有地方可连。没有地址时它无避可跳、
    /// 也无处可连，此时唯一正确的行为是保持原样，等组网就绪那一刻再来。
    ///
    /// 为什么值得一条判据：删掉那个早退时**最终**的 `phase` 也会变成 `.awaitingMesh`
    /// （`connect` 的 nil 分支会走到），两种实现看起来收敛到同一个终点 —— 差异只在
    /// 「那拍定时器还在不在」。所以断言必须落在**中途**：调完之后那一拍仍排着。
    func testReconnectNowChangesNothingWithoutAnEndpoint() async throws {
        let transport = WebSocketConnection()
        var endpoint: URL? = URL(string: "http://127.0.0.1:1")
        transport.baseURLProvider = { endpoint }
        transport.authorizationProvider = { "ticket" }
        transport.sessionProvider = { .shared }

        transport.activate()
        // 等握手失败、排上第一拍退避（250–500ms 之后）。
        var waited = 0
        while waited < 40 {
            if case .waiting = transport.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        guard case .waiting = transport.phase else {
            XCTFail("没等到退避拍 —— 先怀疑端点还能连上")
            return
        }

        // 组网掉了：地址消失。此刻叫它「立刻重连」。
        endpoint = nil
        transport.reconnectNow(reason: "test")

        // 还在等那一拍：说明没有被动过。若早退被删，这里会变成 .awaitingMesh。
        guard case .waiting = transport.phase else {
            XCTFail("无地址时 reconnectNow 动了状态：\(transport.phase)"
                    + " —— 它把排着的退避取消掉了，而那句话此刻无避可跳")
            return
        }
        transport.deactivate()
    }

    // MARK: - U6：退避与代次由传输层自己决定

    /// 连不上时：阶段按 `connecting → waiting(ms) → connecting` 循环，每一代都重新来一遍。
    /// 判据盯的是**观察到两次以上 `.connecting`** —— 每一代握手都置它一次，
    /// 于是「代次在递增」有了一个不依赖内部字段的观测点。
    func testAFailingEndpointKeepsCyclingPhaseWithoutLeavingIdle() async throws {
        let transport = transport()
        var phases: [ConnectionPhase] = []
        transport.onPhaseChanged = { _, new in phases.append(new) }

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
        let transport = WebSocketConnection()
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

    /// 一条流都没有也要连 —— 「常驻」的字面含义就是这句。
    ///
    /// 停在会话列表时正是这个处境：没有流，连接仍在；也正因为如此，半开连接才会被发现。
    func testTheConnectionIsResidentWithoutAnyStream() {
        var handshakes = 0
        let transport = WebSocketConnection()
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
    func testOpeningASecondStreamKeepsThePhase() async throws {
        let (transport, streams) = transportWithStreams()
        transport.activate()
        let ok = #"{"type":"item","streamId":"nobody","payload":{"kind":"ready"}}"#
        transport.handleMessage(.string(ok), generation: 1)
        await drain(transport)
        XCTAssertEqual(transport.phase, .ready)

        _ = try XCTUnwrap(streams.makeStream(Behavior()))
        _ = try XCTUnwrap(streams.makeStream(Behavior()))

        XCTAssertEqual(transport.phase, .ready, "开流不改阶段")
        // 正控：有连接时造流真的发 open。这一组其余各处都断言 `sentFrames` **为空**，
        // 而「send 根本不记账」会让那几条断言一起变成永远为真。
        XCTAssertEqual(transport.sentFrames.count, 2, "两条流就是两条 open")
        transport.deactivate()
    }

    /// 单帧接收上限必须是网关承诺上界的两倍：系统默认 1 MiB 正是「某个会话打不开」的成因。
    func testTheFrameCeilingIsTwiceTheGatewayCap() {
        XCTAssertEqual(WebSocketConnection.maximumMessageSize, 8 * 1024 * 1024)
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
        renewed.reconnectNow(reason: "test")
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

    // MARK: - 回前台：停在 ready 的半死连接

    /// 半开连接（对端进程死了、NAT 静默丢了映射）**停在 `.ready`** —— 于是「回前台就重连」
    /// 若只看阶段，就永远碰不到它，只能等 60 秒的心跳判死。
    ///
    /// 判据分两半：纯判定穷举四格（阶段 × 证据），再加一条打适配器的 —— 只有后者能证明
    /// `reconnectNow` 真的问了那个判定。
    func testForegroundReconnectVerdict() {
        let now = Date()
        let grace: TimeInterval = 6

        // 握手中：一次握手正在路上，再插一次只会把它掐掉。
        XCTAssertFalse(WebSocketConnection.shouldReconnectOnForeground(
            phase: .connecting, lastEvidenceAt: now, now: now, grace: grace))

        // 就绪且刚有证据：不重连 —— 每次回前台都白掐一条好连接。
        XCTAssertFalse(WebSocketConnection.shouldReconnectOnForeground(
            phase: .ready, lastEvidenceAt: now.addingTimeInterval(-1), now: now, grace: grace),
            "宽限之内不该重连")

        // 就绪但证据过期：重连。这一格就是半开连接。
        XCTAssertTrue(WebSocketConnection.shouldReconnectOnForeground(
            phase: .ready, lastEvidenceAt: now.addingTimeInterval(-7), now: now, grace: grace),
            "超过宽限没有任何证据 = 半开连接，该重连")

        // 就绪但从没收到过证据：不知道该不该信它，重连一次比干等强。
        XCTAssertTrue(WebSocketConnection.shouldReconnectOnForeground(
            phase: .ready, lastEvidenceAt: nil, now: now, grace: grace))

        // 其余阶段本来就没有连接在手，一律重连。
        XCTAssertTrue(WebSocketConnection.shouldReconnectOnForeground(
            phase: .waiting(ms: 1_000), lastEvidenceAt: now, now: now, grace: grace))
        XCTAssertTrue(WebSocketConnection.shouldReconnectOnForeground(
            phase: .awaitingMesh, lastEvidenceAt: now, now: now, grace: grace))
    }

    /// 适配器那一半：`reconnectNow` 在就绪且静默时真的会重连。
    func testForegroundReconnectWakesASilentReadyConnection() async {
        let silent = transport()
        silent.activate()
        silent.handleMessage(.string(#"{"type":"item","streamId":"nobody","payload":{}}"#),
                             generation: 1)
        await drain(silent)
        XCTAssertEqual(silent.phase, .ready, "前置：这一代真的通了")

        // 刚收到帧：宽限之内，什么都不该发生。
        silent.reconnectNow(reason: "foreground")
        XCTAssertEqual(silent.phase, .ready, "刚有证据就不该重连")

        // 把宽限压到 0，等价于「证据已经过期」—— 重连必须发生。
        silent.evidenceGrace = 0
        silent.reconnectNow(reason: "foreground")
        XCTAssertEqual(silent.phase, .connecting, "证据过期后回前台必须重连")
        silent.deactivate()
    }
}
