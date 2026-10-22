/**
 * 连接层的**流级**行为：编号、路由、注销身份、启停与流分离。
 *
 * 这一组判据都落在**产品入口**上（`activate` / `open` / `close` / `reopenStream` / `route`），
 * 不引入测试专用开关 —— 行为改坏了，红的是这些断言，而不是某个只活在测试里的镜像实现。
 *
 * 为什么这些事值得单独断言：它们**不会编译失败**。编号复用了、注销关错了流、别的流的帧
 * 进了判读器 —— 三种都表现为屏幕上的偶然：「切会话后停在正在同步」「旧会话的内容闪一下」。
 * 真机看得见但说不清，所以判据得钉在这里。
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
    private func connected() -> FollowClient {
        let follow = FollowClient()
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        follow.authorizationProvider = { "ticket" }
        follow.sessionProvider = { .shared }
        return follow
    }

    private func subscription(
        _ subscriber: Subscriber,
        label: String = "s1"
    ) -> FollowClient.Subscription {
        FollowClient.Subscription(
            owner: subscriber,
            label: label,
            build: { id in
                subscriber.built.append(id)
                return #"{"type":"open","streamId":"\#(id)"}"#
            },
            handler: { _, _ in
                subscriber.handled += 1
                return StreamReply()
            }
        )
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

        // 换订阅者：旧流作废，新流拿另一个号。
        let second = Subscriber()
        follow.open(subscription(second))
        XCTAssertEqual(second.built.count, 1)
        XCTAssertNotEqual(second.built[0], first.built[0],
                          "换订阅者必须换号 —— 编号不复用正是「旧残帧进不了新画面」的前提")

        follow.deactivate()
    }

    // MARK: - O3：注销带订阅者身份

    func testALateUnregisterDoesNotTouchTheNewStream() {
        let follow = connected()
        let first = Subscriber()
        let second = Subscriber()

        follow.open(subscription(first))
        follow.activate()
        follow.open(subscription(second)) // 换订阅者：cancel(first) + open(second)
        let afterSwitch = follow.sentFrames.count
        XCTAssertEqual(afterSwitch, 3, "换订阅者 = 取消旧的 + 开新的，加上最初那一帧")

        // 上一屏的收尾晚到了：它不得碰这一屏的流。
        follow.close(owner: first)
        XCTAssertEqual(follow.sentFrames.count, afterSwitch, "晚到的注销一条帧都不该发")
        XCTAssertEqual(follow.streamId, second.built[0], "它的流还在，编号还是自己的")

        // 真正的注销：发取消，且取消的是自己那一条。
        follow.close(owner: second)
        XCTAssertEqual(follow.sentFrames.count, afterSwitch + 1, "自己的注销发一帧取消")
        XCTAssertTrue(follow.sentFrames.last?.contains(second.built[0]) == true,
                      "取消帧指向的必须是自己的编号")
        XCTAssertNil(follow.streamId, "注销之后没有流了")

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
        let mine = try XCTUnwrap(follow.streamId, "登记之后应当有一个编号")

        // 上一条流的尾巴：编号不是本流 —— 连判读都不该发生。
        //
        // 走**产品入口** `handleMessage`（不是直接调 `route`）：这里要断的是两件事的
        // 顺序 —— 先记「对端还活着」，再按编号归流。直接调 `route` 只测得到后一半，
        // 而前一半（残帧仍算活着的证据）才是「切会话不掉线」的那一环。
        follow.handleMessage(.string(#"{"type":"item","streamId":"someone-else"}"#), generation: 1)
        XCTAssertEqual(subscriber.handled, 0, "别的编号的帧不许进订阅方")
        XCTAssertTrue(follow.heardFromPeer, "但它仍然是对端活着的证据 —— 丢了会让健康连接被心跳判死")

        // 本流的帧照常投递。
        follow.handleMessage(.string(#"{"type":"item","streamId":"\#(mine)"}"#), generation: 1)
        XCTAssertEqual(subscriber.handled, 1, "本流的帧照常投递")

        // 连接级帧（审批）没有编号，不属于任何一条流 —— 不归流，照旧交出去。
        follow.handleMessage(.string(#"{"type":"approval"}"#), generation: 1)
        XCTAssertEqual(subscriber.handled, 2, "连接级帧不归流")

        follow.deactivate()
    }

    // MARK: - O7：重开换号

    func testReopeningCancelsTheOldIdAndOpensWithAFreshOne() throws {
        let follow = connected()
        let subscriber = Subscriber()
        follow.open(subscription(subscriber))
        follow.activate()

        let before = try XCTUnwrap(follow.streamId)
        let sentBefore = follow.sentFrames.count

        follow.reopenStream()

        XCTAssertEqual(follow.sentFrames.count, sentBefore + 2, "重开 = 一帧取消 + 一帧开流")
        let cancel = try XCTUnwrap(follow.sentFrames.dropFirst(sentBefore).first)
        XCTAssertTrue(cancel.contains(#""type":"cancel""#), "先停旧的那一条")
        XCTAssertTrue(cancel.contains(before), "取消帧指向旧编号")

        let after = try XCTUnwrap(follow.streamId)
        XCTAssertNotEqual(after, before,
                          "重开必须换号 —— 同号会被网关当成「已占用」而静默忽略，只能等就绪超时")
        XCTAssertTrue(follow.sentFrames.last?.contains(after) == true, "新的开流帧带新编号")

        follow.deactivate()
    }
}
