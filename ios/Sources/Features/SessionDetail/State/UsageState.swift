import Foundation

/// 上下文占用的**吸收** —— 一台纯值类型（不 import SwiftUI / UIKit）。
///
/// 只管一件事：这条帧该不该覆盖手里那份。百分比与紧凑数字的换算不在这里，在
/// `Display/UsageDisplay.swift` —— 它随界面口径变，不随协议变（R18 期2 D1）。
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

    /// 当前该显示的占用值。为 `nil` 时界面**隐藏整行** —— 「没有读数」不是「占用 0%」。
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
