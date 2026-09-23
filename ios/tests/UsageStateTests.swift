/**
 * UsageState 的吸收测试（O1–O2）：纯值类型，不碰网络 / UI / 持久化。
 *
 * 判据与出处：docs/dev/plans/M6-presentation-layer.md §五。吸收规则照上游
 * `api/session-controller/src/client/sessions/projection-store.ts:136` ——
 * **严格高 seq 胜，相等也丢**。
 */
import Foundation

@main
struct UsageStateTests {

    /// 带值的快照；不给 `used`/`window` 就是「这个水位上无可显示的东西」。
    private static func snapshot(_ seq: Int, _ used: Int? = nil, window: Int? = nil) -> UsageSnapshot {
        guard let used, let window else { return UsageSnapshot(asOfSeq: seq, usage: nil) }
        return UsageSnapshot(
            asOfSeq: seq,
            usage: UsagePayload(usedTokens: used, contextWindow: window)
        )
    }

    static func main() {
        var state = UsageState()
        expect(state.usage == nil, "O1a 初始无占用值")

        var verdict = state.apply(snapshot(120, 52_300, window: 128_000))
        expect(verdict == .accepted && state.usage?.usedTokens == 52_300, "O1b 首帧落地")

        verdict = state.apply(snapshot(90, 10_000, window: 128_000))
        expect(verdict == .stale && state.usage?.usedTokens == 52_300, "O1c 小水位被丢，显示不倒退")

        verdict = state.apply(snapshot(120, 999, window: 128_000))
        expect(verdict == .stale && state.usage?.usedTokens == 52_300, "O1d 同水位重放被丢")

        verdict = state.apply(snapshot(121, 60_000, window: 128_000))
        expect(verdict == .accepted && state.usage?.usedTokens == 60_000, "O1e 大水位照常覆盖")

        // O1f：占用消失也算一次推进。
        verdict = state.apply(snapshot(122))
        expect(verdict == .accepted && state.usage == nil, "O1f 清空帧被接受")

        verdict = state.apply(snapshot(100, 5_000, window: 128_000))
        expect(verdict == .stale && state.usage == nil, "O1g 清空后旧帧不能复活它")

        // O2：显示换算照上游 —— 取整封顶、紧凑数字、读数行恒带「约」。
        let half = UsagePayload(usedTokens: 52_300, contextWindow: 128_000)
        expect(half.percent == 41, "O2a 52300/128000 → 41%（四舍五入，不是截断）")
        expect(half.figures == "~52.3K / 128K", "O2b 读数行：一位小数的 K 与整数的 K")
        expect(UsagePayload(usedTokens: 200_000, contextWindow: 100_000).percent == 100, "O2c 超出容量封顶 100")
        expect(UsagePayload(usedTokens: 10, contextWindow: 0).percent == 100, "O2d 分母为 0 封顶 100 且不崩")
        expect(formatTokens(517) == "517", "O2e 不足一千原样")
        expect(formatTokens(1_200) == "1.2K", "O2f 一千出头保留一位小数")
        expect(formatTokens(517_000) == "517K", "O2g 尾数 ≥100 取整")
        expect(formatTokens(1_200_000) == "1.2M", "O2h 百万级")

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }
}
