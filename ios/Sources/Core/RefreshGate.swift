/**
 * 刷新合并闸 —— 纯判定，时钟与调度由持有方（`SessionSync`）注入。
 *
 * 事件到达 → 开批并调度一次 flush；批开着 → 只累计不重复调度；到点 → 关批，持有方全量重算。
 * 未定稿帧与占用帧**不经过本闸**：它们的路径里没有全量组装。
 */
import Foundation

struct RefreshGate {
    enum Arrival: Equatable {
        /// 批未开：开批，持有方应调度一次 flush。
        case openWindow
        /// 批已开：只累计，不重复调度。
        case accumulate
    }

    private(set) var batchOpen = false

    /// 一条事件帧到达。
    mutating func eventArrived() -> Arrival {
        if batchOpen { return .accumulate }
        batchOpen = true
        return .openWindow
    }

    /// flush 到点：关批并回报批是否开着（没开 = 无事发生，不重算）。
    mutating func flushDue() -> Bool {
        defer { batchOpen = false }
        return batchOpen
    }
}
