/**
 * 刷新合并闸（R4 决定 2）—— 纯判定，时钟与调度由持有方（SessionSync）注入。
 *
 * 语义：事件到达 → 开批并调度一次 flush；批开着 → 只累计不重复调度；flush 到点
 * → 关批，持有方做一次全量重算。组合起来给出「刷新次数 ≤ 事件数」的上界
 * （判据 G3），同时保留「整段重算优于增量」的既有决策——降的是频率，不是正确性。
 *
 * 未定稿（流式输出）帧与占用帧**不经过本闸**：前者逐帧更新自己的文本，后者由
 * `UsageState` 判定丢弃——它们的路径里没有全量组装。
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
