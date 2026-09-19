/**
 * TransientChannel 的接缝测试（TC1–TC7）。
 *
 * 与 `SessionMirrorTests` 同一手法：状态机不碰网络、不碰 UI、不碰持久化，
 * 这里没有服务器也没有文件系统 —— 每条断言都由状态机自己决定。
 *
 * 断言清单与出处：docs/plans/M2-realtime-transient.md §5.2（C2 对应 TC3/TC4/TC5）。
 */
import Foundation

@main
struct TransientChannelTests {

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

    // MARK: - JSON 便捷构造

    private static func object(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }

    private static func chunk(_ index: Int, revision: Int = 3, text: String) -> JSONValue {
        object(
            ("type", .string("chunk")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("index", .number(Double(index))),
            ("time", .number(1_700_000_000_000)),
            ("chunk", object(("type", .string("text-delta")), ("index", .number(0)), ("text", .string(text))))
        )
    }

    private static func end(_ revision: Int = 3, chunks: Int) -> JSONValue {
        object(
            ("type", .string("end")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("index", .number(Double(chunks)))
        )
    }

    /// 开场基线：一个已累积了两段文本的 attempt。
    private static func baseline(revision: Int = 3, nextIndex: Int, stream: [String]) -> TransientBaseline {
        TransientBaseline(
            revision: revision,
            active: .init(
                revision: revision,
                nextIndex: nextIndex,
                stream: stream.map { object(("type", .string("text-delta")), ("index", .number(0)), ("text", .string($0))) }
            )
        )
    }

    // MARK: - 用例

    static func main() {
        // TC1：opening 基线恢复 —— 已累积文本与下一个 chunk 位置都对齐。
        var channel = TransientChannel()
        channel.apply(baseline: baseline(nextIndex: 2, stream: ["你好", "，世界"]))
        expect(channel.text == "你好，世界", "TC1a 基线恢复出已累积文本")
        expect(channel.isLive, "TC1b 基线带进行中 attempt ⇒ isLive")

        // TC2：后续 chunk 依序累积。
        var verdict = channel.apply(frame: chunk(2, text: "！"))
        expect(verdict == .consumed && channel.text == "你好，世界！", "TC2 连续 chunk 依序累积")

        // TC3：revision 断号 ⇒ broken（基线已丢，干等只会残缺）。
        verdict = channel.apply(frame: chunk(3, revision: 9, text: "残"))
        expect(verdict == .broken, "TC3 revision 断号判 broken")

        // TC4：index 断号 ⇒ broken。
        channel.apply(baseline: baseline(nextIndex: 5, stream: []))
        verdict = channel.apply(frame: chunk(7, text: "跳"))
        expect(verdict == .broken && channel.text.isEmpty, "TC4 index 断号判 broken 且不改文本")

        // TC5：end 清场 —— committed 的内容随后以持久事件进镜像。
        channel.apply(baseline: baseline(nextIndex: 0, stream: []))
        _ = channel.apply(frame: chunk(0, text: "正在生成"))
        verdict = channel.apply(frame: end(chunks: 1))
        expect(verdict == .ended && channel.text.isEmpty && !channel.isLive, "TC5 end 清场")

        // TC6：非文本 chunk（reasoning 等）跳过文本但仍推进 index。
        channel.apply(baseline: baseline(nextIndex: 0, stream: []))
        let reasoning = object(
            ("type", .string("chunk")),
            ("revision", .number(3)),
            ("index", .number(0)),
            ("chunk", object(("type", .string("reasoning-delta")), ("index", .number(0)), ("text", .string("思考"))))
        )
        verdict = channel.apply(frame: reasoning)
        let after = channel.apply(frame: chunk(1, text: "正文"))
        expect(verdict == .consumed && after == .consumed && channel.text == "正文", "TC6 非文本 chunk 跳过文本、推进 index")

        // TC7：没有进行中 attempt 的基线 ⇒ 干净的空通道。
        var idle = TransientChannel()
        _ = idle.apply(frame: chunk(0, text: "残留"))
        idle.apply(baseline: TransientBaseline(revision: 5, active: nil))
        expect(idle.text.isEmpty && !idle.isLive, "TC7 无 attempt 基线清空一切")

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }
}
