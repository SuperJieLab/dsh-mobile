/**
 * TransientChannel 的契约测试（TC1–TC8）：状态机不碰网络 / UI / 持久化。
 * revision 语义照上游 `agent.ts` 的 `() => ++assistantStreamRevision`：**每帧全局 +1**，
 * start/chunk/end 都占号；
 * `index` 是 attempt 内 chunk 位置，start 后从 0 起。
 * 出处：docs/dev/plans/M2-realtime-transient.md §5.2（C2 对应 TC3/TC4/TC5）。
 */
import Foundation

@main
struct TransientChannelTests {

    // MARK: - JSON 便捷构造

    private static func object(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }

    private static func start(_ revision: Int) -> JSONValue {
        object(
            ("type", .string("start")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("turn", .number(0)),
            ("step", .number(0))
        )
    }

    private static func chunk(_ index: Int, revision: Int, text: String) -> JSONValue {
        object(
            ("type", .string("chunk")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("index", .number(Double(index))),
            ("time", .number(1_700_000_000_000)),
            ("chunk", object(("type", .string("text-delta")), ("index", .number(0)), ("text", .string(text))))
        )
    }

    private static func end(_ revision: Int, chunks: Int) -> JSONValue {
        object(
            ("type", .string("end")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("index", .number(Double(chunks)))
        )
    }

    /// 开场基线：已用掉 `usedRevision` 号；attempt 内已累积 `stream`，下一 chunk 位置 `nextIndex`。
    private static func baseline(usedRevision: Int, nextIndex: Int, stream: [String]) -> TransientBaseline {
        TransientBaseline(
            revision: usedRevision,
            active: .init(
                nextIndex: nextIndex,
                stream: stream.map { object(("type", .string("text-delta")), ("index", .number(0)), ("text", .string($0))) }
            )
        )
    }

    // MARK: - 用例

    static func main() {
        // TC1：opening 基线恢复 —— 已累积文本对齐，期望 revision = 已用号 + 1。
        var channel = TransientChannel()
        channel.apply(baseline: baseline(usedRevision: 3, nextIndex: 2, stream: ["你好", "，世界"]))
        expect(channel.text == "你好，世界", "TC1a 基线恢复出已累积文本")
        expect(channel.isLive, "TC1b 基线带进行中 attempt ⇒ isLive")

        // TC2：基线之后的第一帧 revision 必须 = 已用号 + 1；chunk 依序累积。
        var verdict = channel.apply(frame: chunk(2, revision: 4, text: "！"))
        expect(verdict == .consumed && channel.text == "你好，世界！", "TC2 chunk（revision=基线+1, index=nextIndex）依序累积")
        verdict = channel.apply(frame: chunk(3, revision: 5, text: "欢迎"))
        expect(verdict == .consumed && channel.text == "你好，世界！欢迎", "TC2b 第二帧继续 +1/+1")

        // TC3：revision 跳号 ⇒ broken（基线已丢，干等只会残缺）。
        channel = TransientChannel()
        channel.apply(baseline: baseline(usedRevision: 3, nextIndex: 0, stream: []))
        verdict = channel.apply(frame: chunk(0, revision: 9, text: "跳"))
        expect(verdict == .broken, "TC3 revision 跳号判 broken")

        channel = TransientChannel()
        channel.apply(baseline: baseline(usedRevision: 3, nextIndex: 5, stream: []))
        verdict = channel.apply(frame: chunk(7, revision: 4, text: "跳"))
        expect(verdict == .broken && channel.text.isEmpty, "TC4 index 断号判 broken 且不改文本")

        // TC5：start → chunk → end 的完整 attempt。
        channel = TransientChannel()
        channel.apply(baseline: baseline(usedRevision: 0, nextIndex: 0, stream: []))
        verdict = channel.apply(frame: start(1))
        expect(verdict == .consumed && channel.isLive, "TC5a start 落地")
        _ = channel.apply(frame: chunk(0, revision: 2, text: "正在生成"))
        verdict = channel.apply(frame: end(3, chunks: 1))
        expect(verdict == .ended && channel.text.isEmpty && !channel.isLive, "TC5b end 清场")

        // TC6：非文本 chunk（reasoning 等）跳过文本但 revision/index 照常推进。
        channel.apply(baseline: baseline(usedRevision: 10, nextIndex: 0, stream: []))
        _ = channel.apply(frame: start(11))
        let reasoning = object(
            ("type", .string("chunk")),
            ("revision", .number(12)),
            ("index", .number(0)),
            ("chunk", object(("type", .string("reasoning-delta")), ("index", .number(0)), ("text", .string("思考"))))
        )
        verdict = channel.apply(frame: reasoning)
        let after = channel.apply(frame: chunk(1, revision: 13, text: "正文"))
        expect(verdict == .consumed && after == .consumed && channel.text == "正文", "TC6 非文本 chunk 跳过文本、序号照常推进")

        // TC7：没有进行中 attempt 的基线 ⇒ 干净的空通道（但 revision 水位已对齐）。
        var idle = TransientChannel()
        _ = idle.apply(frame: chunk(0, revision: 1, text: "残留"))
        idle.apply(baseline: TransientBaseline(revision: 5, active: nil))
        expect(idle.text.isEmpty && !idle.isLive, "TC7a 无 attempt 基线清空一切")
        verdict = idle.apply(frame: start(6))
        expect(verdict == .consumed, "TC7b 基线后的 start 用 revision+1")

        // TC8：多 attempt —— 第二个 attempt 的 start 之后 index 重置、revision 继续。
        channel = TransientChannel()
        channel.apply(baseline: baseline(usedRevision: 0, nextIndex: 0, stream: []))
        _ = channel.apply(frame: start(1))
        _ = channel.apply(frame: chunk(0, revision: 2, text: "第一轮"))
        _ = channel.apply(frame: end(3, chunks: 1))
        verdict = channel.apply(frame: start(4))
        let second = channel.apply(frame: chunk(0, revision: 5, text: "第二轮"))
        expect(verdict == .consumed && second == .consumed && channel.text == "第二轮", "TC8 新 attempt：index 重置、revision 续走")

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }
}
