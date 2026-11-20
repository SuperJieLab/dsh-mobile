/**
 * UsageState 的吸收测试（O1–O2）：纯值类型，不碰网络 / UI / 持久化。
 *
 * 吸收规则照上游
 * 客户端只回答「这条帧该不该覆盖手里那份」：快照按严格高 `asOfSeq`，control 接管后直接覆盖 ——
 */
import Foundation
import XCTest

@testable import DshMobile

final class UsageStateTests: XCTestCase {

    /// 带值的快照；不给 `used`/`window` 就是「这个水位上无可显示的东西」。
    private func snapshot(_ seq: Int, _ used: Int? = nil, window: Int? = nil) -> UsageSnapshot {
        guard let used, let window else { return UsageSnapshot(asOfSeq: seq, usage: nil) }
        return UsageSnapshot(
            asOfSeq: seq,
            usage: UsagePayload(usedTokens: used, contextWindow: window)
        )
    }

    func testUsageAbsorption() {
        var state = UsageState()
        XCTAssertTrue(state.usage == nil, "O1a 初始无占用值")

        var verdict = state.apply(snapshot(120, 52_300, window: 128_000))
        XCTAssertTrue(verdict == .accepted && state.usage?.usedTokens == 52_300, "O1b 首帧落地")

        verdict = state.apply(snapshot(90, 10_000, window: 128_000))
        XCTAssertTrue(verdict == .stale && state.usage?.usedTokens == 52_300, "O1c 小水位被丢，显示不倒退")

        verdict = state.apply(snapshot(120, 999, window: 128_000))
        XCTAssertTrue(verdict == .stale && state.usage?.usedTokens == 52_300, "O1d 同水位重放被丢")

        verdict = state.apply(snapshot(121, 60_000, window: 128_000))
        XCTAssertTrue(verdict == .accepted && state.usage?.usedTokens == 60_000, "O1e 大水位照常覆盖")

        // O1f：占用消失也算一次推进。
        verdict = state.apply(snapshot(122))
        XCTAssertTrue(verdict == .accepted && state.usage == nil, "O1f 清空帧被接受")

        verdict = state.apply(snapshot(100, 5_000, window: 128_000))
        XCTAssertTrue(verdict == .stale && state.usage == nil, "O1g 清空后旧帧不能复活它")

        // O2：显示换算照上游 —— 取整封顶、紧凑数字、读数行恒带「约」。
        let half = UsagePayload(usedTokens: 52_300, contextWindow: 128_000)
        XCTAssertTrue(half.percent == 41, "O2a 52300/128000 → 41%（四舍五入，不是截断）")
        XCTAssertTrue(half.figures == "~52.3K / 128K", "O2b 读数行：一位小数的 K 与整数的 K")
        XCTAssertTrue(UsagePayload(usedTokens: 200_000, contextWindow: 100_000).percent == 100, "O2c 超出容量封顶 100")
        XCTAssertTrue(UsagePayload(usedTokens: 10, contextWindow: 0).percent == 100, "O2d 分母为 0 封顶 100 且不崩")
        XCTAssertTrue(formatTokens(517) == "517", "O2e 不足一千原样")
        XCTAssertTrue(formatTokens(1_200) == "1.2K", "O2f 一千出头保留一位小数")
        XCTAssertTrue(formatTokens(517_000) == "517K", "O2g 尾数 ≥100 取整")
        XCTAssertTrue(formatTokens(1_200_000) == "1.2M", "O2h 百万级")
    }
    /// 两条来源的覆盖规则：control 接管之后，快照那条路（`apply`）不许再覆盖。
    ///
    /// 两条水位不同轴（快照是投影切点，control 是事件 seq），所以「比 asOfSeq」在这里
    /// 没有可比性 —— 只测「新的能进」会漏掉「旧值借低位通过」与「新值被旧水位挡住」两种错序。
    func testControlTakesOverAndSnapshotCannotOverride() {
        var state = UsageState()
        state.adopt(UsagePayload(usedTokens: 50, contextWindow: 100))
        let verdict = state.apply(UsageSnapshot(asOfSeq: 295, usage: UsagePayload(usedTokens: 90, contextWindow: 100)))
        XCTAssertEqual(verdict, .stale, "control 已接管，快照的旧值必须被拒")
        XCTAssertEqual(state.usage?.usedTokens, 50)
    }

    /// 反序：快照先到，control 后到仍然覆盖（control 是权威）。
    func testControlOverridesAnEarlierSnapshot() {
        var state = UsageState()
        _ = state.apply(UsageSnapshot(asOfSeq: 295, usage: UsagePayload(usedTokens: 90, contextWindow: 100)))
        state.adopt(UsagePayload(usedTokens: 50, contextWindow: 100))
        XCTAssertEqual(state.usage?.usedTokens, 50, "control 必须先验")
    }

    /// control 的更新一条条采纳，包括「读数消失」（`nil` → 隐藏整行）。
    func testControlUpdatesAreAdoptedInOrder() {
        var state = UsageState()
        state.adopt(UsagePayload(usedTokens: 50, contextWindow: 100))
        state.adopt(UsagePayload(usedTokens: 55, contextWindow: 100))
        XCTAssertEqual(state.usage?.usedTokens, 55)
        state.adopt(nil)
        XCTAssertNil(state.usage, "读数消失也要采纳 —— 界面该隐藏整行，不是停在 55")
    }

    /// `adopt(nil)` 之后来快照：仍是 `.stale`。接管是单向的 —— control 说「没有读数」也是
    /// 它的判断，快照不该把旧值补回来。
    func testSnapshotStaysStaleAfterControlAdoptsNothing() {
        var state = UsageState()
        state.adopt(nil)
        let verdict = state.apply(UsageSnapshot(asOfSeq: 999, usage: UsagePayload(usedTokens: 90, contextWindow: 100)))
        XCTAssertEqual(verdict, .stale)
        XCTAssertNil(state.usage)
    }

}
