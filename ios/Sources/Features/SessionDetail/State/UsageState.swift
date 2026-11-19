import Foundation

/// 上下文占用的**吸收** —— 纯值类型（不 import SwiftUI / UIKit）。
///
/// 两条来源、两套规则：快照（`apply`）在 control 接管之前按「严格高 `asOfSeq` 才采用」；
/// control（`adopt`）接管之后**直接覆盖**，快照一律变 `.stale` —— 两者水位不同轴，不可比。
/// 百分比与紧凑数字的换算不在这里，在 `Display/UsageDisplay.swift`；读数为 `nil` 时界面
/// 显示 `--`（不是隐藏整行）。
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

    /// control 是否已经接管。一旦接管，快照那条路（`apply`）不再覆盖 —— R4 把 control
    /// 定为权威，而两条来源的水位不同轴（快照是投影切点，control 是事件 seq），
    /// 用同一个 `asOfSeq` 去比必然出现「旧值借低位通过」或「新值被旧水位挡住」。
    private var controlAdopted = false

    /// 当前该显示的占用值。为 `nil` 时界面**隐藏整行** —— 「没有读数」不是「占用 0%」。
    var usage: UsagePayload? { snapshot?.usage }

    /// 收一条帧。
    /// - Parameter next: 帧里那份读数（含自己的水位）。
    /// - Returns: `.accepted` 已生效；`.stale` 比手里的旧，已丢弃。
    @discardableResult
    mutating func apply(_ next: UsageSnapshot) -> Verdict {
        // control 接管之后，快照只配当历史：它的水位与 control 不同轴，没有可比性。
        if controlAdopted { return .stale }
        if let current = snapshot, next.asOfSeq <= current.asOfSeq { return .stale }
        snapshot = next
        return .accepted
    }

    /// control 流的更新：**权威且单流有序**，不比水位。
    ///
    /// 两条来源的水位不同轴：快照的 `projections.asOfSeq` 是投影切点，control 的
    /// `projection.seq` 是引发变化的事件 —— 拿一个去比另一个是错的（`ControlStream`
    /// 的文件头解释了这一点）。control 在单条流内有序到达，重放由它自己挡掉（`seq` 不前进
    /// 就丢），所以到这里只需采纳；采纳之后 `apply` 不再覆盖（`controlAdopted`）。
    ///
    /// 保留旧 `asOfSeq` 只为一个用途：`snapshot` 的字段类型要求它存在，而这份值此后不再
    /// 参与任何比较。
    mutating func adopt(_ payload: UsagePayload?) {
        controlAdopted = true
        snapshot = UsageSnapshot(asOfSeq: snapshot?.asOfSeq ?? 0, usage: payload)
    }
}
