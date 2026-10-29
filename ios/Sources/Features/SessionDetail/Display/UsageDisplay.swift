/**
 * 上下文占用的**显示换算** —— 百分比、`~52.3K / 128K`、紧凑 token 数。
 *
 * 变化原因与 `State/UsageState` 不同：那边判「该不该覆盖」（随协议变），这边算「怎么写给
 * 人看」（随界面口径变）。算法照上游：百分比封顶 100，紧凑数字尾数 ≥100 取整。
 */
import Foundation

extension UsagePayload {

    /// 百分比：`min(100, round(used / window * 100))` —— 与上游同一个式子，不另立换算。
    var percent: Int {
        // 分母为 0 时上游得 Infinity、被 `min(100, ·)` 封成 100；Swift `Int(infinity)` 会崩，
        // 故走同一条出口。
        guard contextWindow > 0 else { return 100 }
        return min(100, Int((Double(usedTokens) / Double(contextWindow) * 100).rounded()))
    }

    /// 面板上那一串读数：`~52.3K / 128K`。**「约」无条件加** —— 上游把它硬写在
    /// 模板里，不区分这个数来自哪个投影字段。
    var figures: String { "~\(formatTokens(usedTokens)) / \(formatTokens(contextWindow))" }

    /// 那一个大字百分比。`"\(percent)%"` 这种拼法有两个消费方（详情面板与功能条那一格），
    /// 各自拼一遍就会在「要不要空格」「要不要四舍五入」上分叉。
    var percentText: String { "\(percent)%" }
}

/// 紧凑 token 数：`517` / `12.2K` / `517K` / `1.2M`。尾数 ≥100
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
