/**
 * 跟随承载下的镜像重放测试（C3）与退避曲线测试（C1 可测部分）。
 *
 * ## C3 —— 「连接必然断」对新承载的压力测试（docs/dev/plans/M2-realtime-transient.md §5.2）
 *
 * 跟随流喂给镜像的形状是刻意选的：opening 就是 `page` 的窗口（`Window`），
 * 一条事件帧就是一次覆盖到 `seq + 1` 的快照（`Snapshot`）。所以这里**不碰
 * `SessionSync`、不碰网络**，直接按跟随流的投喂顺序重放 —— M1 的那台状态机
 * 若需要为 WebSocket 改任何一行，这里的断言就会先红。
 *
 * ## C1 的可测部分
 *
 * `FollowClient` 的重连编排需要真网络，完整行为由真机判据 R3/R4 覆盖；这里
 * 测它的**退避曲线**（纯函数）：指数爬升、抖动边界、封顶。
 */
import Foundation

@main
struct FollowReplayTests {

    private static var passed = 0
    private static var failed = 0

    private static func expect(_ ok: Bool, _ label: String) {
        if ok {
            passed += 1
            print("ok   \(label)")
        } else {
            failed += 1
            print("FAIL \(label)")
        }
    }

    private static func event(_ seq: Int, text: String = "m") -> SessionEvent {
        SessionEvent(type: seq % 2 == 0 ? "user/message" : "assistant/message", seq: seq, time: 1_700_000_000_000 + Double(seq), data: .object([:]))
    }

    static func main() {

        // MARK: C3 —— 跟随流按投喂顺序重放进同一台镜像

        var mirror = SessionMirror()

        // ① opening：50 条的尾窗（此处缩成 3 条示意），就是一次 `page` 的形状。
        let openingEvents = [event(2), event(3), event(4)]
        let opening = Window(pageStart: 2, asOfSeq: 5, hasOlder: true, events: openingEvents)
        expect({
            if case .merged = mirror.open(with: opening) { return true }
            return false
        }(), "C3-1 opening 经 mirror.open 落地（与 page 同一入口）")
        expect(mirror.cursor == 5 && mirror.pageStart == 2 && mirror.hasOlder, "C3-2 水位与窗口起点由 opening 钉住")

        // ② 事件帧：一条 = 一次覆盖到 seq+1 的快照。重复投递也被幂等吸收。
        let first = mirror.apply(.received(Snapshot(asOfSeq: 6, hasMore: false, events: [event(5)])))
        expect({
            if case .merged(let added) = first { return added == 1 }
            return false
        }(), "C3-3 事件帧按快照语义追加")
        expect(mirror.cursor == 6, "C3-4 游标推进到 seq+1")

        let duplicate = mirror.apply(.received(Snapshot(asOfSeq: 7, hasMore: false, events: [event(6)])))
        _ = duplicate
        let replayed = mirror.apply(.received(Snapshot(asOfSeq: 7, hasMore: false, events: [event(6)])))
        expect({
            if case .caughtUp = replayed { return true }
            return false
        }(), "C3-5 重复投递被幂等吸收（重连竞态的必然后果）")

        // ③ 断线 → 重新 open：新 opening **替换**窗口（不做水位续传）。
        //    断线期间服务端发生了 7..10 的事件，新 opening 的窗口覆盖 4..11。
        let rebuildEvents = [event(4), event(5), event(6), event(7), event(8), event(9), event(10)]
        let rebuilt = Window(pageStart: 4, asOfSeq: 11, hasOlder: true, events: rebuildEvents)
        expect({
            if case .merged = mirror.open(with: rebuilt) { return true }
            return false
        }(), "C3-6 重连后的新 opening 以替换落地")
        expect(mirror.cursor == 11 && mirror.events.first?.seq == 4, "C3-7 重建后的视图完整覆盖断线期间的事件")
        expect(mirror.events.count == rebuildEvents.count, "C3-8 替换不累积旧内容（窗口重建，不是追加）")

        // MARK: C1 —— 退避曲线（纯函数）

        // 指数爬升：attempt 1..5 的封顶值依次 500、1000、2000、4000、8000。
        expect(FollowClient.backoffDelayMs(attempt: 1, random: 1) == 500, "C1-1 attempt 1 封顶 500ms")
        expect(FollowClient.backoffDelayMs(attempt: 2, random: 1) == 1_000, "C1-2 attempt 2 封顶 1s")
        expect(FollowClient.backoffDelayMs(attempt: 5, random: 1) == 8_000, "C1-3 attempt 5 封顶 8s")

        // 封顶：指数再大也不超过 10s。
        expect(FollowClient.backoffDelayMs(attempt: 30, random: 1) == 10_000, "C1-4 封顶 10s")

        // 抖动：random 0 给封顶的 50%，random 1 给 100%。
        expect(FollowClient.backoffDelayMs(attempt: 3, random: 0) == 1_000, "C1-5 抖动下界 = 封顶的 50%")
        expect(FollowClient.backoffDelayMs(attempt: 3, random: 0.5) == 1_500, "C1-6 抖动中点")

        // 输入钳制：越界的 attempt 与 random 不产生离谱值。
        expect(FollowClient.backoffDelayMs(attempt: 0, random: 1) == 500, "C1-7 attempt 0 按 1 处理")
        expect(FollowClient.backoffDelayMs(attempt: 3, random: 99) == 2_000, "C1-8 random 越界被钳到 1")

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }
}
