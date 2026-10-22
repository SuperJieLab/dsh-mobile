/**
 * 连接层的**流级**行为：编号、路由、注销身份、启停与流分离、一条流坏了不动另一条。
 *
 * 这一组判据都落在**产品入口**上（`activate` / `open` / `close` / `reopen` / `connect` /
 * `route`），不引入测试专用开关 —— 行为改坏了，红的是这些断言，而不是某个只活在测试里的
 * 镜像实现。
 *
 * 为什么这些事值得单独断言：它们**不会编译失败**。编号复用了、注销关错了流、别的流的帧
 * 进了判读器、一条流被拒把整条连接拽断 —— 四种都表现为屏幕上的偶然：「切会话后停在正在
 * 同步」「旧会话的内容闪一下」「事件流一开，会话就不动了」。真机看得见但说不清，所以判据
 * 得钉在这里。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class StreamLayerTests: XCTestCase {

    /// 订阅者替身：只做**身份**与计数，不含任何判定。
    ///
    /// `owner` 比对是对象身份（`===`），所以它必须是个 class —— 这正是 SwiftUI 重建视图时
    /// 「新的 `SessionSync` 与被注销的那个」之间的关系。
    private final class Subscriber {
        var built: [StreamId] = []
        var handled = 0
    }

    /// 一个有端点、有票的连接层：握手会真发起（连到 `127.0.0.1:1`，必定失败），但**发帧是
    /// 同步完成的** —— 断言紧跟在动作之后，看的是处理完那一刻的状态。
    ///
    /// ⚠️ 这个端点握手失败之后，连接层自己会按退避换届次（0.25–0.5 秒一拍），每一代都把
    /// 所有流换成新号。所以这一组判据**只写同步断言**：任何 `await` 之后的编号都可能是
    /// 重连换的，用它做断言等于在测重连。
    private func connected() -> FollowClient {
        let follow = FollowClient()
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        follow.authorizationProvider = { "ticket" }
        follow.sessionProvider = { .shared }
        return follow
    }

    private func subscription(
        _ subscriber: Subscriber,
        label: String = "s1",
        verdict: @escaping (MuxServerEnvelope) -> StreamReply = { _ in StreamReply() }
    ) -> FollowClient.Subscription {
        FollowClient.Subscription(
            owner: subscriber,
            label: label,
            build: { id in
                subscriber.built.append(id)
                return #"{"type":"open","streamId":"\#(id)"}"#
            },
            handler: { envelope, _ in
                subscriber.handled += 1
                return verdict(envelope)
            }
        )
    }

    /// 判读的替身：**直接给出「这条流接下来怎么办」**。
    ///
    /// 从线上文本到那句话的映射归 `SessionStreamReader`（它有自己的一组判据）；这里要问的是
    /// 连接层拿到那句话之后怎么做 —— 两个问题分开放，一边红了才说得清是谁错了。
    private func verdicts(_ byType: [String: StreamNext]) -> (MuxServerEnvelope) -> StreamReply {
        { envelope in
            guard let next = byType[envelope.type] else { return StreamReply() }
            return StreamReply(next: next)
        }
    }

    /// 收到 `item` 即建成 —— 判决不改动动作。
    private func establishesOnItem(_ envelope: MuxServerEnvelope) -> StreamReply {
        StreamReply(establishes: envelope.type == "item")
    }

    /// 一条带编号的帧，只有外壳 —— 归流只需要外壳。
    private func frame(_ id: StreamId) -> URLSessionWebSocketTask.Message {
        .string(#"{"type":"item","streamId":"\#(id)"}"#)
    }

    // MARK: - O4：编号现造、不复用；登记不丢也不重

    func testEachRegistrationMintsAFreshIdAndSendsOneOpen() {
        let follow = connected()
        let first = Subscriber()

        // 登记，但还没要连接：只拼文本，一个字节都不发。
        follow.open(subscription(first))
        XCTAssertEqual(first.built.count, 1, "登记时就该凭新编号拼一次开流文本")
        XCTAssertEqual(follow.sentFrames.count, 0, "没有连接时不得假装发过帧")

        follow.activate()
        XCTAssertEqual(follow.sentFrames.count, 1, "连上之后恰好发一次 open —— 排队不丢也不重")
        XCTAssertTrue(follow.sentFrames[0].contains(first.built[0]),
                      "发出去的必须是这一条流的文本（编号对得上）")

        // 同一个订阅者重复登记：幂等。视图重算不该换掉这条流。
        follow.open(subscription(first))
        XCTAssertEqual(first.built.count, 1, "同一订阅者重复登记不得换号")
        XCTAssertEqual(follow.sentFrames.count, 1, "也不得重发一帧")

        // 另一个订阅者：第二条流，另一个号；两条流并存，谁也不顶掉谁。
        let second = Subscriber()
        follow.open(subscription(second))
        XCTAssertEqual(second.built.count, 1)
        XCTAssertNotEqual(second.built[0], first.built[0],
                          "不同的流必须不同的号 —— 编号不复用正是「旧残帧进不了新画面」的前提")
        XCTAssertEqual(follow.streamId(of: first), first.built[0], "先登记者那条流还在")

        follow.deactivate()
    }

    // MARK: - O3：注销带订阅者身份

    /// 注销只注销**自己那一次登记**：晚到的注销一帧都不发，也不碰别人的流。
    func testUnregisterOnlyTouchesItsOwnRegistration() throws {
        let follow = connected()
        let first = Subscriber()
        let second = Subscriber()

        follow.open(subscription(first))
        follow.activate()
        let firstId = try XCTUnwrap(follow.streamId(of: first))

        follow.close(owner: first)
        XCTAssertEqual(follow.sentFrames.count, 2, "注销 = 一帧取消")
        XCTAssertTrue(follow.sentFrames.last?.contains(firstId) == true, "取消帧指向自己的编号")
        XCTAssertNil(follow.streamId(of: first), "注销之后这一条流没了")

        follow.open(subscription(second))
        let afterOpen = follow.sentFrames.count
        XCTAssertEqual(afterOpen, 3, "新的订阅者开自己那一条流")

        // 上一屏的收尾晚到了：它不得碰这一屏的流。
        follow.close(owner: first)
        XCTAssertEqual(follow.sentFrames.count, afterOpen, "晚到的注销一条帧都不该发")
        XCTAssertEqual(follow.streamId(of: second), second.built[0], "它的流还在，编号还是自己的")

        follow.close(owner: second)
        XCTAssertEqual(follow.sentFrames.count, afterOpen + 1, "自己的注销发一帧取消")
        XCTAssertNil(follow.streamId(of: second), "注销之后没有流了")

        follow.deactivate()
    }

    // MARK: - O2：连接不要流也能活着

    func testTheConnectionDoesNotNeedAStream() {
        let follow = FollowClient()
        var handshakes = 0
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        follow.authorizationProvider = { "ticket" }
        follow.sessionProvider = {
            handshakes += 1
            return .shared
        }

        follow.activate()
        XCTAssertEqual(handshakes, 1, "没有登记任何流也该连 —— 常驻的字面含义就是这句")
        XCTAssertTrue(follow.sentFrames.isEmpty, "没有流就没有开流帧可发")

        follow.deactivate()
        XCTAssertEqual(follow.phase, .idle, "收掉之后没有连接，也没有排定的重试")
    }

    // MARK: - O5：帧按编号归流

    func testFramesForAnotherStreamNeverReachTheSubscriber() throws {
        let follow = connected()
        let subscriber = Subscriber()
        follow.open(subscription(subscriber))
        follow.activate()
        let mine = try XCTUnwrap(follow.streamId(of: subscriber), "登记之后应当有一个编号")

        // 上一条流的尾巴：编号不是本流 —— 连判读都不该发生。
        //
        // 走**产品入口** `handleMessage`（不是直接调 `route`）：这里要断的是两件事的
        // 顺序 —— 先记「对端还活着」，再按编号归流。直接调 `route` 只测得到后一半，
        // 而前一半（残帧仍算活着的证据）才是「切会话不掉线」的那一环。
        follow.handleMessage(frame("someone-else"), generation: 1)
        XCTAssertEqual(subscriber.handled, 0, "别的编号的帧不许进订阅方")
        XCTAssertTrue(follow.heardFromPeer, "但它仍然是对端活着的证据 —— 丢了会让健康连接被心跳判死")

        // 本流的帧照常投递。
        follow.handleMessage(frame(mine), generation: 1)
        XCTAssertEqual(subscriber.handled, 1, "本流的帧照常投递")

        // 连接级帧（审批）没有编号：走投递口，不进任何一条流。
        follow.handleMessage(.string(#"{"type":"approval"}"#), generation: 1)
        XCTAssertEqual(subscriber.handled, 1, "无编号帧不属于任何流")

        follow.deactivate()
    }

    // MARK: - 无编号帧的归属

    /// 投递口的替身：只记收到哪几帧。
    private final class Sink: UnscopedFrameSink {
        var frames: [MuxServerEnvelope] = []
        func accept(_ frame: MuxServerEnvelope) { frames.append(frame) }
    }

    /// 没有编号的帧走投递口，**不进任何一条流**：它不属于流，属于连接。
    ///
    /// 三种帧各一次，三个方向缺一不可 —— 只断「sink 收到了」的话，「同时也给了某条流」
    /// 会漏过去，而那种错法的症状是审批被两条路各处理一遍。
    func testUnscopedFramesGoToTheSinkAndNeverToAStream() throws {
        let follow = connected()
        let subscriber = Subscriber()
        let sink = Sink()
        follow.open(subscription(subscriber))
        follow.unscopedSink = sink
        follow.activate()
        let mine = try XCTUnwrap(follow.streamId(of: subscriber))

        follow.handleMessage(.string(#"{"type":"approval","payload":{"kind":"cancel"}}"#),
                             generation: 1)
        XCTAssertEqual(sink.frames.map(\.type), ["approval"], "无编号帧该进投递口")
        XCTAssertEqual(subscriber.handled, 0, "它不属于任何流 —— 一条都不该看见")

        follow.handleMessage(frame(mine), generation: 1)
        XCTAssertEqual(subscriber.handled, 1, "有编号的帧照常归流")
        XCTAssertEqual(sink.frames.count, 1, "有编号的帧不进投递口")

        follow.handleMessage(frame("nobody"), generation: 1)
        XCTAssertEqual(sink.frames.count, 1, "编号不认识的帧两处都不去")
        XCTAssertEqual(subscriber.handled, 1)

        follow.deactivate()
    }

    /// 没有收货人时，无编号帧被丢掉 —— 不崩、也不退回去找一条流代收。
    func testWithoutASinkUnscopedFramesAreDropped() {
        let follow = connected()
        let subscriber = Subscriber()
        follow.open(subscription(subscriber))
        follow.activate()

        follow.handleMessage(.string(#"{"type":"approval"}"#), generation: 1)
        XCTAssertEqual(subscriber.handled, 0, "退回给某条流代收正是这一版要消掉的那条规则")
    }

    // MARK: - 门面的转发

    /// `GatewayLink` 的三个转发成员真的转到了连接层。
    ///
    /// 这一跳两端各有判据（连接层「谁收无编号帧」、表「收到之后怎么处理」），而**中间**
    /// 没有：把 setter 写成空实现，两边都绿，症状是「审批永不显示」。
    func testTheFacadeForwardsTheSinkToTheConnection() throws {
        let follow = FollowClient()
        let link = GatewayLink(client: GatewayClient(), follow: follow)
        let sink = Sink()

        link.unscopedSink = sink

        XCTAssertTrue(follow.unscopedSink === sink, "门面的 setter 没转到连接层")
        XCTAssertTrue(link.unscopedSink === sink, "读回来的也必须是同一个")

        // 反向：换一个收货人，连接层跟着换 —— 写死的 getter 不会红，写死的 setter 会。
        let other = Sink()
        follow.unscopedSink = other
        XCTAssertTrue(link.unscopedSink === other)
    }

    // MARK: - O7：重开换号

    func testReopeningCancelsTheOldIdAndOpensWithAFreshOne() throws {
        let follow = connected()
        let subscriber = Subscriber()
        follow.open(subscription(subscriber))
        follow.activate()

        let before = try XCTUnwrap(follow.streamId(of: subscriber))
        let sentBefore = follow.sentFrames.count

        follow.reopen(owner: subscriber)

        XCTAssertEqual(follow.sentFrames.count, sentBefore + 2, "重开 = 一帧取消 + 一帧开流")
        let cancel = try XCTUnwrap(follow.sentFrames.dropFirst(sentBefore).first)
        XCTAssertTrue(cancel.contains(#""type":"cancel""#), "先停旧的那一条")
        XCTAssertTrue(cancel.contains(before), "取消帧指向旧编号")

        let after = try XCTUnwrap(follow.streamId(of: subscriber))
        XCTAssertNotEqual(after, before,
                          "重开必须换号 —— 同号会被网关当成「已占用」而静默忽略，只能等就绪超时")
        XCTAssertTrue(follow.sentFrames.last?.contains(after) == true, "新的开流帧带新编号")

        follow.deactivate()
    }

    // MARK: - O10：两条流并存，按号归流

    /// 会话流与事件流挂同一条连接：编号帧各归各，无编号帧只进**声明了**的那一条，
    /// 且开一条新流不打回「连接中」。
    ///
    /// 登记顺序**刻意**让事件流在前：无编号帧的归属判据是「声明」而不是「先登记」，
    /// 两个条件重合时这条判据分不出两者，那种写法会把「谁先开谁收」放过去。
    func testTwoStreamsRouteSeparatelyAndOpeningASecondKeepsThePhase() throws {
        let follow = connected()
        let session = Subscriber()
        let events = Subscriber()
        follow.open(subscription(events, label: "events"))
        follow.open(subscription(session, label: "s1", verdict: establishesOnItem))
        follow.activate()

        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        let eventsId = try XCTUnwrap(follow.streamId(of: events))
        XCTAssertNotEqual(sessionId, eventsId, "两条流两个号")
        XCTAssertEqual(follow.sentFrames.count, 2, "两条流各发一帧开流")

        // 会话流建成 ⇒ 连接就绪。
        follow.handleMessage(frame(sessionId), generation: 1)
        XCTAssertEqual(follow.phase, .ready, "建成即就绪")

        // 就绪之后再开第三条流：连接没变，阶段不该回退成「连接中」。
        let late = Subscriber()
        follow.open(subscription(late, label: "late"))
        XCTAssertEqual(follow.phase, .ready,
                       "在就绪的连接上开一条新流不得把阶段打回 connecting —— 屏幕会闪一下「连接中」")

        // 按号归流：B 的帧不进 A，A 的帧不进 B。
        follow.handleMessage(frame(eventsId), generation: 1)
        XCTAssertEqual(events.handled, 1, "事件流收到自己那一条")
        XCTAssertEqual(session.handled, 1, "会话流的计数没被 B 的帧动过")

        follow.handleMessage(frame(sessionId), generation: 1)
        XCTAssertEqual(session.handled, 2)
        XCTAssertEqual(events.handled, 1)

        // 无编号帧（审批）走投递口：两条流都不该看见它。
        follow.handleMessage(.string(#"{"type":"approval"}"#), generation: 1)
        XCTAssertEqual(session.handled, 2, "无编号帧不属于任何流")
        XCTAssertEqual(events.handled, 1)

        follow.deactivate()
    }

    // MARK: - O11：重连逐流换号重开

    /// 一次重连（新代次）之后，每条流都用自己的新编号重开 —— 四条 open、四个互不相同的号。
    func testReconnectReopensEveryStreamWithAFreshId() throws {
        let follow = connected()
        let session = Subscriber()
        let events = Subscriber()
        follow.open(subscription(session, label: "s1"))
        follow.open(subscription(events, label: "events"))
        follow.activate()

        let sessionFirst = try XCTUnwrap(follow.streamId(of: session))
        let eventsFirst = try XCTUnwrap(follow.streamId(of: events))

        follow.connect() // 模拟 socket 断了再连：新代次，每条流各重开一次

        let sessionSecond = try XCTUnwrap(follow.streamId(of: session))
        let eventsSecond = try XCTUnwrap(follow.streamId(of: events))
        XCTAssertEqual(session.built, [sessionFirst, sessionSecond], "会话流两次各一个新号")
        XCTAssertEqual(events.built, [eventsFirst, eventsSecond], "事件流两次各一个新号")
        XCTAssertEqual(Set([sessionFirst, sessionSecond, eventsFirst, eventsSecond]).count, 4,
                       "四条 open 必须四个互不相同的号 —— 复用会让旧流的收尾删到新流的登记")

        follow.deactivate()
    }

    // MARK: - O12：事件流的拒绝与收尾

    /// 事件流被拒（这台网关不认这个 op）：**只收起这一条流**，连接与会话流照常。
    func testAnEventsRefusalStopsThatStreamOnly() throws {
        let follow = connected()
        let session = Subscriber()
        let events = Subscriber()
        follow.open(subscription(session, label: "s1", verdict: establishesOnItem))
        follow.open(subscription(events, label: "events", verdict: verdicts(["error": .stop])))
        follow.activate()

        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        let eventsId = try XCTUnwrap(follow.streamId(of: events))
        follow.handleMessage(frame(sessionId), generation: 1)
        let sentBefore = follow.sentFrames.count

        follow.handleMessage(.string("""
        {"type":"error","streamId":"\(eventsId)","payload":{"code":"unknown-op","message":""}}
        """), generation: 1)

        XCTAssertNil(follow.streamId(of: events), "被拒的事件流收起来了")
        XCTAssertEqual(follow.sentFrames.count, sentBefore, "终态不该再开一条 —— 再开只会收同一次拒绝")
        XCTAssertEqual(follow.phase, .ready, "连接没被打回等待 —— 一条流的拒绝不动连接")

        // 会话流照常收帧。
        follow.handleMessage(frame(sessionId), generation: 1)
        XCTAssertEqual(session.handled, 2, "会话流不受影响")

        // 连接仍在：给会话流发注销还能发出去（没有连接时 `send` 什么都不发）。
        follow.close(owner: session)
        XCTAssertEqual(follow.sentFrames.count, sentBefore + 1, "连接还在 —— 取消帧发得出去")

        follow.deactivate()
    }

    /// 事件流被服务端正常收尾：换号在当前连接上重开一次。
    func testAnEventsEndReopensItWithAFreshId() throws {
        let follow = connected()
        let session = Subscriber()
        let events = Subscriber()
        follow.open(subscription(session, label: "s1"))
        follow.open(subscription(events, label: "events", verdict: verdicts(["end": .reopen])))
        follow.activate()

        let eventsId = try XCTUnwrap(follow.streamId(of: events))
        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        let sentBefore = follow.sentFrames.count

        follow.handleMessage(.string(#"{"type":"end","streamId":"\#(eventsId)"}"#), generation: 1)

        let reopened = try XCTUnwrap(follow.streamId(of: events))
        XCTAssertNotEqual(reopened, eventsId, "收尾之后换号")
        XCTAssertEqual(events.built.count, 2, "重开一次 —— 不是每次收尾都排一条新流")
        XCTAssertEqual(follow.sentFrames.count, sentBefore + 2, "一帧取消 + 一帧开流")
        XCTAssertEqual(follow.streamId(of: session), sessionId, "会话流的号不动")

        follow.deactivate()
    }

    // MARK: - O15：会话流的拒绝只作用于它

    /// 非终态拒绝（`internal-error`）走**这条流自己的退避**：旧号作废、新号就位，但这个当口
    /// **不发** open（要等退避到点）；连接与另一条流一帧都不动。
    ///
    /// 「退避」与「立即」的差别就是这两帧：`.retry` 当场只发一帧取消，`.reopen` 当场发两帧。
    /// 退避到点那一拍不在这里等 —— 这个端点握手必定失败，等待期间连接层会自己换届次、
    /// 把每条流的号都换掉，那时断言落在重连上而不是「这一条流被拒之后怎么了」。
    func testARefusedSessionStreamRetriesOnItsOwn() throws {
        let follow = connected()
        let session = Subscriber()
        let events = Subscriber()
        follow.open(subscription(session, label: "s1") { [self] envelope in
            envelope.type == "error" ? StreamReply(next: .retry) : establishesOnItem(envelope)
        })
        follow.open(subscription(events, label: "events"))
        follow.activate()

        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        let eventsId = try XCTUnwrap(follow.streamId(of: events))
        follow.handleMessage(frame(sessionId), generation: 1)
        XCTAssertEqual(follow.phase, .ready, "会话流建成 ⇒ 连接就绪")
        let sentBefore = follow.sentFrames.count

        follow.handleMessage(.string("""
        {"type":"error","streamId":"\(sessionId)","payload":{"code":"internal-error","message":""}}
        """), generation: 1)

        let pending = try XCTUnwrap(follow.streamId(of: session), "这条流还在，只是换成了新的号")
        XCTAssertNotEqual(pending, sessionId, "旧号当场作废 —— 被拒的那条流不会再有内容")
        XCTAssertEqual(session.built.count, 2, "换号在排这一拍的时候就发生了")
        XCTAssertEqual(follow.sentFrames.count, sentBefore + 1, "只发一帧取消：open 要等退避到点")
        XCTAssertTrue(follow.sentFrames.last?.contains(sessionId) == true, "取消的是旧号")
        XCTAssertEqual(follow.phase, .ready,
                       "拒绝不动连接 —— 这正是「一条流坏了拖断另一条」的反面")
        XCTAssertEqual(follow.streamId(of: events), eventsId, "事件流的号不动")
    }

    /// 退避在途时用户按「重试」：立刻换号开出去，而不是等那一拍。
    ///
    /// 这一条也守着「换号不能让在途那一拍重发」：`retryNow` 的前置（这条流已发出 open、
    /// 或已建成就不做）挡住同一个号被开两次 —— 网关把重复编号当协议违规，会关掉整条连接。
    func testReopeningDuringBackoffOpensImmediately() throws {
        let follow = connected()
        let session = Subscriber()
        follow.open(subscription(session, label: "s1") { [self] envelope in
            envelope.type == "error" ? StreamReply(next: .retry) : establishesOnItem(envelope)
        })
        follow.activate()

        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        follow.handleMessage(frame(sessionId), generation: 1)
        follow.handleMessage(.string("""
        {"type":"error","streamId":"\(sessionId)","payload":{"code":"internal-error","message":""}}
        """), generation: 1)

        let pending = try XCTUnwrap(follow.streamId(of: session))
        let sentAfterRetry = follow.sentFrames.count

        follow.reopen(owner: session)

        XCTAssertEqual(follow.sentFrames.count, sentAfterRetry + 2,
                       "用户要它现在就开：一帧取消 + 一帧开流，不等退避")
        XCTAssertTrue(follow.sentFrames[sentAfterRetry].contains(pending),
                      "取消的是那个还没发出去的号")
        let reopened = try XCTUnwrap(follow.streamId(of: session))
        XCTAssertNotEqual(reopened, pending, "换号，不复用")
        XCTAssertTrue(follow.sentFrames.last?.contains(reopened) == true, "开流帧带新号")
    }

    /// 终态拒绝（`unreadable-session`）：收起这一条，连接与另一条流照常。
    func testATerminalRefusalStopsThatStreamOnly() throws {
        let follow = connected()
        let session = Subscriber()
        let events = Subscriber()
        follow.open(subscription(session, label: "s1",
                                 verdict: verdicts(["error": .stop])))
        follow.open(subscription(events, label: "events"))
        follow.activate()

        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        let eventsId = try XCTUnwrap(follow.streamId(of: events))
        let sentBefore = follow.sentFrames.count

        follow.handleMessage(.string("""
        {"type":"error","streamId":"\(sessionId)","payload":{"code":"unreadable-session","message":""}}
        """), generation: 1)

        XCTAssertNil(follow.streamId(of: session), "终态：这一条收起来了")
        XCTAssertEqual(follow.sentFrames.count, sentBefore, "不再重开 —— 重连只会再收一次同样的拒绝")
        XCTAssertEqual(follow.streamId(of: events), eventsId, "事件流不受影响")

        follow.handleMessage(frame(eventsId), generation: 1)
        XCTAssertEqual(events.handled, 1, "连接还在，事件流照常收帧")

        follow.deactivate()
    }

    // MARK: - 退避到点那一拍

    /// 那一拍要不要真的发 open —— 三种处境，缺一种就写错一个方向。
    ///
    /// 它单独成一条判据是因为**真机判据在这一点上做不到**：这里的端点握手必定失败，连接层
    /// 每 0.25–0.5 秒换届次、把每条流换成新号再发一遍 —— 等待期里的任何一帧都分不清是
    /// 「这一拍发的」还是「重连发的」。而它错了的症状是静默的：会话流被非终态拒一次之后，
    /// 这一屏永久停在「正在同步」，日志里除了 `retry in Nms` 再没有下文。
    func testOnlyAnIdleUnbuiltStreamOpensWhenItsBackoffElapses() {
        XCTAssertTrue(FollowClient.shouldOpenOnRetry(openInFlight: false, established: false),
                      "既没在途也没建成 —— 这一拍就是为它排的")
        XCTAssertFalse(FollowClient.shouldOpenOnRetry(openInFlight: true, established: false),
                       "同一个号重发 open 会被网关判成重复编号，**关掉整条连接**")
        XCTAssertFalse(FollowClient.shouldOpenOnRetry(openInFlight: false, established: true),
                       "已经建成：这一拍已被重连或用户提前满足了")
    }

    /// 被拒之后那一拍**排上了**：它不是「当场不发」，而是「等一会儿再发」。
    ///
    /// 少了它，`scheduleRetry` 里漏掉 `asyncAfter` 与「退避」看起来一模一样 —— 都是当场
    /// 只发一帧取消，而「到点」那半只写在注释里。
    func testARefusedStreamLeavesARetryPendingOnTheQueue() throws {
        let follow = connected()
        let session = Subscriber()
        let other = Subscriber()
        follow.open(subscription(session, label: "s1") { [self] envelope in
            envelope.type == "error" ? StreamReply(next: .retry) : establishesOnItem(envelope)
        })
        follow.open(subscription(other, label: "s2"))
        follow.activate()

        let sessionId = try XCTUnwrap(follow.streamId(of: session))
        follow.handleMessage(frame(sessionId), generation: 1)
        XCTAssertFalse(follow.isWaitingToRetry(owner: session), "刚建成时没有在等的退避")

        follow.handleMessage(.string("""
        {"type":"error","streamId":"\(sessionId)","payload":{"code":"internal-error","message":""}}
        """), generation: 1)

        XCTAssertTrue(follow.isWaitingToRetry(owner: session), "被拒之后要真的排上一拍")
        XCTAssertFalse(follow.isWaitingToRetry(owner: other), "另一条流没被拒，不该排")

        follow.deactivate()
    }
}
