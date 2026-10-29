import Foundation

/// 上下文占用的**吸收** —— 纯值类型（不 import SwiftUI / UIKit）。
/// 只管一件事：这条帧该不该覆盖手里那份 —— **严格高 seq 才采用**，等于也丢（重放会重复）。
/// 百分比与紧凑数字的换算不在这里，在 `Display/UsageDisplay.swift`。
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

    /// 当前该显示的占用值。为 `nil` 时界面**隐藏整行** —— 「没有读数」不是「占用 0%」。
    var usage: UsagePayload? { snapshot?.usage }

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
