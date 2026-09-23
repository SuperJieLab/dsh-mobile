import Foundation

/// 上下文占用的吸收 —— 一台纯值类型（不 import SwiftUI / UIKit）。
///
/// 服务端每次重读投影、**值有变化**才推一条 `usage` 帧，帧里带这次重读的水位 `asOfSeq`。
/// 客户端只回答一个问题：这条帧该不该覆盖手里那份。规则照上游客户端
/// （`api/session-controller/src/client/sessions/projection-store.ts:136`）：**严格高 seq
/// 胜 —— 相等也丢**，于是乱序与重放都不会让显示倒退、新水位的帧不会被误拒。
///
/// 不做「值相同就不换」这种更聪明的比较：帧本就是因为值变了才发的（服务端有同一条判定），
/// 客户端再比一次值只会多一个判错的机会；水位是服务端给的、单调的，当唯一判据就够。
struct UsageState: Equatable {

    /// 一条帧的处置结果。
    enum Verdict: Equatable {
        /// 水位推进了，采用 —— 视图需要重画。
        case accepted
        /// 水位没推进（乱序到达或重放），已丢弃。
        case stale
    }

    /// 已经采用的那一份读数；`nil` = 还没有收到过任何帧。
    private(set) var snapshot: UsageSnapshot?

    /// 当前该显示的占用值。为 `nil` 时界面**隐藏整行** —— 「没有读数」不是「占用 0%」
    /// （判据 U2）。
    var usage: UsagePayload? { snapshot?.usage }

    init() {}

    /// 收一条帧。
    /// - Parameter next: 帧里那份读数（含自己的水位）。
    /// - Returns: `.accepted` 已生效；`.stale` 比手里的旧，已丢弃。
    @discardableResult
    mutating func apply(_ next: UsageSnapshot) -> Verdict {
        if let current = snapshot, next.asOfSeq <= current.asOfSeq { return .stale }
        snapshot = next
        return .accepted
    }
}

// MARK: - 显示换算

/// 取整、封顶与紧凑数字都在这一侧（服务端只定值），算法照上游 —— R1 判据
/// 「与 Web UI 一致」量的是这三件事，不是别的。
extension UsagePayload {

    /// 百分比：`min(100, round(used / window * 100))`（`context-occupancy.ts:21`）。
    var percent: Int {
        // 分母为 0 时上游得 Infinity、被 `min(100, ·)` 封成 100；Swift `Int(infinity)` 会崩，
        // 故走同一条出口。
        guard contextWindow > 0 else { return 100 }
        return min(100, Int((Double(usedTokens) / Double(contextWindow) * 100).rounded()))
    }

    /// 面板上那一串读数：`~52.3K / 128K`。**「约」无条件加** —— 上游把它硬写在
    /// 模板里，不区分这个数来自哪个投影字段（§3.1 决定 5）。
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
