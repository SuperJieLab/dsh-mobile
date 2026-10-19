/**
 * 上下文占用的**显示换算** —— 百分比、`~52.3K / 128K`、紧凑 token 数。
 *
 * 与 `State/UsageState.swift` 分家的理由：那边判「这条读数该不该覆盖」（随协议变），
 * 这边算「怎么把它写给人看」（随界面口径变 —— 「与 Web UI 一致」这条验收量的是这三件事）。
 *
 * 算法照上游（`context-occupancy.ts:21`、`ContextMeter.tsx:40-47`）：百分比取整后封顶 100；
 * 紧凑数字尾数 ≥100 时取整、否则保留一位小数；「约」无条件加。
 *
 * 消费者：`OccupancyBar`（一行读数与展开区）。
 */
import Foundation

extension UsagePayload {

    /// 百分比：`min(100, round(used / window * 100))`（`context-occupancy.ts:21`）。
    var percent: Int {
        // 分母为 0 时上游得 Infinity、被 `min(100, ·)` 封成 100；Swift `Int(infinity)` 会崩，
        // 故走同一条出口。
        guard contextWindow > 0 else { return 100 }
        return min(100, Int((Double(usedTokens) / Double(contextWindow) * 100).rounded()))
    }

    /// 面板上那一串读数：`~52.3K / 128K`。**「约」无条件加** —— 上游把它硬写在
    /// 模板里，不区分这个数来自哪个投影字段。
    var figures: String { "~\(formatTokens(usedTokens)) / \(formatTokens(contextWindow))" }
}

/// 紧凑 token 数：`517` / `12.2K` / `517K` / `1.2M`（`ContextMeter.tsx:40-47`）。尾数 ≥100
/// 时取整、否则保留一位小数 —— 与上游同一个判据，故不写成通用的「保留几位有效数字」。
func formatTokens(_ value: Int) -> String {
    func scaled(_ candidate: Double) -> String {
        candidate >= 100
            ? String(Int(candidate.rounded()))
            : String((candidate * 10).rounded() / 10)
    }
    if value < 1_000 { return String(value) }
    if value < 1_000_000 { return "\(scaled(Double(value) / 1_000))K" }
    return "\(scaled(Double(value) / 1_000_000))M"
}
