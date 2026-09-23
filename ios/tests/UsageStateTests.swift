/**
 * UsageState 的吸收测试（O1）。
 *
 * 与 `SessionMirrorTests` / `TransientChannelTests` 同一手法：占用值是纯值类型，
 * 不碰网络、不碰 UI、不碰持久化 —— 这里没有服务器，也没有 WebSocket。
 *
 * 判据与出处：docs/dev/plans/M6-presentation-layer.md §五（O1）。吸收规则照上游
 * `api/session-controller/src/client/sessions/projection-store.ts:136` ——
 * **严格高 seq 胜，相等也丢**。
 */
import Foundation

@main
struct UsageStateTests {

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

    /// 带值的快照；不给 `used`/`window` 就是「这个水位上无可显示的东西」。
    private static func snapshot(_ seq: Int, _ used: Int? = nil, window: Int? = nil) -> UsageSnapshot {
        guard let used, let window else { return UsageSnapshot(asOfSeq: seq, usage: nil) }
        return UsageSnapshot(
            asOfSeq: seq,
            usage: UsagePayload(usedTokens: used, contextWindow: window)
        )
    }

    static func main() {
        // O1a：空状态没有任何可显示的东西。
        var state = UsageState()
        expect(state.usage == nil, "O1a 初始无占用值")

        // O1b：第一帧落地。
        var verdict = state.apply(snapshot(120, 52_300, window: 128_000))
        expect(verdict == .accepted && state.usage?.usedTokens == 52_300, "O1b 首帧落地")

        // O1c：水位更小的帧被丢弃 —— 迟到的旧帧不能把显示往回拽。
        verdict = state.apply(snapshot(90, 10_000, window: 128_000))
        expect(verdict == .stale && state.usage?.usedTokens == 52_300, "O1c 小水位被丢，显示不倒退")

        // O1d：同一水位的重放被丢弃 —— 显示不变。
        verdict = state.apply(snapshot(120, 999, window: 128_000))
        expect(verdict == .stale && state.usage?.usedTokens == 52_300, "O1d 同水位重放被丢")

        // O1e：水位更大的帧照常覆盖（新水位不被误拒）。
        verdict = state.apply(snapshot(121, 60_000, window: 128_000))
        expect(verdict == .accepted && state.usage?.usedTokens == 60_000, "O1e 大水位照常覆盖")

        // O1f：占用消失也是一次推进 —— 显示随之清空。
        verdict = state.apply(snapshot(122))
        expect(verdict == .accepted && state.usage == nil, "O1f 清空帧被接受")

        // O1g：清空之后，旧帧不能把它复活。
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
