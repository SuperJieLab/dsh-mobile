/**
 * 跟随承载下的镜像重放（C3）与退避曲线（C1 可测部分）。
 *
 * ## C3（M2 §5.2）
 * 跟随流的形状：opening 即 `page` 的窗口（`Window`），一条事件帧即一次覆盖到
 * `seq + 1` 的快照（`Snapshot`）。不碰 `SessionSync`、不碰网络，按投喂顺序重放 ——
 * M1 那台状态机若为 WebSocket 改任何一行，这里先红。
 *
 * ## C1 的可测部分
 * `FollowClient` 的重连编排需真网络，完整行为由真机判据 R3/R4 覆盖；这里测它的
 * **退避曲线**（纯函数）：指数爬升、抖动边界、封顶。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class FollowReplayTests: XCTestCase {

    private func event(_ seq: Int, text: String = "m") -> SessionEvent {
        SessionEvent(type: seq % 2 == 0 ? "user/message" : "assistant/message", seq: seq, time: 1_700_000_000_000 + Double(seq), data: .object([:]))
    }

    func testReplayAndBackoff() async {

        // MARK: C3 —— 跟随流按投喂顺序重放进同一台镜像

        var mirror = SessionMirror()

        // ① opening：50 条的尾窗（此处缩成 3 条示意），就是一次 `page` 的形状。
        let openingEvents = [event(2), event(3), event(4)]
        let opening = Window(pageStart: 2, asOfSeq: 5, hasOlder: true, events: openingEvents)
        XCTAssertTrue({
            if case .merged = mirror.open(with: opening) { return true }
            return false
        }(), "C3-1 opening 经 mirror.open 落地（与 page 同一入口）")
        XCTAssertTrue(mirror.cursor == 5 && mirror.pageStart == 2 && mirror.hasOlder, "C3-2 水位与窗口起点由 opening 钉住")

        // ② 事件帧：一条 = 一次覆盖到 seq+1 的快照。重复投递也被幂等吸收。
        let first = mirror.apply(.received(Snapshot(asOfSeq: 6, hasMore: false, events: [event(5)])))
        XCTAssertTrue({
            if case .merged(let added) = first { return added == 1 }
            return false
        }(), "C3-3 事件帧按快照语义追加")
        XCTAssertTrue(mirror.cursor == 6, "C3-4 游标推进到 seq+1")

        let duplicate = mirror.apply(.received(Snapshot(asOfSeq: 7, hasMore: false, events: [event(6)])))
        _ = duplicate
        let replayed = mirror.apply(.received(Snapshot(asOfSeq: 7, hasMore: false, events: [event(6)])))
        XCTAssertTrue({
            if case .caughtUp = replayed { return true }
            return false
        }(), "C3-5 重复投递被幂等吸收（重连竞态的必然后果）")

        // ③ 断线 → 重新 open：新 opening **替换**窗口（不做水位续传）；
        // 断线期间服务端发生了 7..10 的事件，新 opening 覆盖 4..11。
        let rebuildEvents = [event(4), event(5), event(6), event(7), event(8), event(9), event(10)]
        let rebuilt = Window(pageStart: 4, asOfSeq: 11, hasOlder: true, events: rebuildEvents)
        XCTAssertTrue({
            if case .merged = mirror.open(with: rebuilt) { return true }
            return false
        }(), "C3-6 重连后的新 opening 以替换落地")
        XCTAssertTrue(mirror.cursor == 11 && mirror.events.first?.seq == 4, "C3-7 重建后的视图完整覆盖断线期间的事件")
        XCTAssertTrue(mirror.events.count == rebuildEvents.count, "C3-8 替换不累积旧内容（窗口重建，不是追加）")

        // MARK: C1 —— 退避曲线（纯函数）

        // 指数爬升：attempt 1..5 的封顶值依次 500、1000、2000、4000、8000。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 1, random: 1) == 500, "C1-1 attempt 1 封顶 500ms")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 2, random: 1) == 1_000, "C1-2 attempt 2 封顶 1s")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 5, random: 1) == 8_000, "C1-3 attempt 5 封顶 8s")

        // 封顶：指数再大也不超过 10s。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 30, random: 1) == 10_000, "C1-4 封顶 10s")

        // 抖动：random 0 给封顶的 50%，random 1 给 100%。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 3, random: 0) == 1_000, "C1-5 抖动下界 = 封顶的 50%")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 3, random: 0.5) == 1_500, "C1-6 抖动中点")

        // 输入钳制：越界的 attempt 与 random 不产生离谱值。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 0, random: 1) == 500, "C1-7 attempt 0 按 1 处理")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 3, random: 99) == 2_000, "C1-8 random 越界被钳到 1")

        // MARK: R4 G1/G2 —— 帧层 typed 解码（对账 + 容错，Plan R4 §3.4 决定 1）

        let openingText = """
        {"type":"item","streamId":1,"payload":{"sessionId":"s1","cursor":3,"pageStart":0,"hasOlder":true,
          "events":[
            {"type":"user/message","seq":1,"time":1700000000000,"data":{}},
            {"type":"user/message","seq":"oops","time":1700000000001,"data":{}},
            {"type":"assistant/message","seq":2,"time":1700000000002,"data":{}}
          ]}}
        """
        let openingData = Data(openingText.utf8)

        // 对账基准：旧的 JSONValue 往返路径（R4 之后代码里不再存在，判定在这里留档）。
        let routed = try! JSONDecoder().decode(JSONValue.self, from: openingData)
        let legacyEvents: [SessionEvent] = ((routed["payload"]?["events"]?.array) ?? []).compactMap {
            try? JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode($0))
        }

        let decodedOpening = OpeningFrame.decode(openingData)
        XCTAssertTrue(opening != nil, "G1a opening 帧原文直解成功")
        XCTAssertTrue(decodedOpening?.events == legacyEvents, "G1b 直解与 JSONValue 往返产出逐字一致")
        XCTAssertTrue(decodedOpening?.cursor == 3 && decodedOpening?.pageStart == 0 && decodedOpening?.hasOlder == true,
                      "G1c 外壳字段（cursor/pageStart/hasOlder）一次解码齐备")

        XCTAssertTrue(decodedOpening?.events.count == 2, "G2a 坏事件（seq 非数字）单条跳过")
        XCTAssertTrue(decodedOpening?.events.first?.seq == 1 && decodedOpening?.events.last?.seq == 2,
                      "G2b 好事件保序保留")

        // 非 opening 形状（缺 cursor/events）如实返回 nil —— 路由判据不变。
        let notOpening = Data(#"{"type":"item","streamId":1,"payload":{"type":"user/message","seq":9,"time":1,"data":{}}}"#.utf8)
        XCTAssertTrue(OpeningFrame.decode(notOpening) == nil, "G2c 非 opening 载荷不误判")

        // MARK: R4 G3 —— 合并闸（Plan R4 §3.4 决定 2）：批内累计，到点收批

        var gate = RefreshGate()
        XCTAssertTrue(gate.eventArrived() == .openWindow, "G3a 批未开：首个事件开批并调度 flush")
        var accumulated = 0
        for _ in 0..<99 where gate.eventArrived() == .accumulate { accumulated += 1 }
        XCTAssertTrue(accumulated == 99, "G3b 批开着：后续 99 个事件只累计，不重复调度")
        XCTAssertTrue(gate.flushDue(), "G3c 到点收批：本批开着 → flush 落地一次")
        XCTAssertTrue(!gate.flushDue(), "G3d 收批之后再 flush 是无事发生（无消费者的重算被挡掉）")
        XCTAssertTrue(gate.eventArrived() == .openWindow, "G3e 关批后新事件重新开批")

        // MARK: R5 K1–K3 —— 端点生命周期（Plan R5 契约：不存在 → activate 一次 → 存在）

        // K1：未激活的 client 不持有端点，op 立抛 .notActivated（transport 尚不存在，零网络）。
        let bare = GatewayClient()
        var k1Hit = false
        do { _ = try await bare.listSessions() } catch GatewayClientError.notActivated { k1Hit = true } catch {}
        XCTAssertTrue(k1Hit, "K1 未激活 op 立抛 notActivated（不猜地址、不发网络）")
        XCTAssertTrue(bare.baseURL == nil, "K1b 未激活端点为 nil")

        // K2：activate 是端点唯一来源——激活后同 op 的失败是传输层（ refusal），不再是 notActivated。
        let activated = GatewayClient()
        let endpoint = URL(string: "http://127.0.0.1:1")!
        activated.activate(session: .shared, baseURL: endpoint)
        XCTAssertTrue(activated.baseURL == endpoint, "K2a 激活后端点 = activate 入参")
        var k2Hit = false
        do { _ = try await activated.listSessions() } catch GatewayClientError.notActivated { k2Hit = false } catch GatewayClientError.transport { k2Hit = true } catch {}
        XCTAssertTrue(k2Hit, "K2b 激活后失败降为传输层错误（端点确实来自 activate）")

        // K3：无端点时跟随流不建连——直接进退避等待，激活后下一轮自愈。
        let follow = FollowClient()
        follow.baseURLProvider = { nil }
        var lastPhase: FollowClient.Phase?
        follow.onPhaseChange = { lastPhase = $0 }
        follow.start(sessionId: "s1")
        XCTAssertTrue({
            if case .waiting = lastPhase { return true }
            return false
        }(), "K3 无端点建连请求 → 不产连接任务，进入退避等待（激活后自愈）")
    }
}
