/**
 * 重连延迟：指数爬升、抖动 50–100%、封顶。
 *
 * 两个调用方分属两层 —— 整条连接的重连与单条流的重试。它们都问同一个问题
 * （「第 n 次失败之后等多久」），所以曲线只有这一份；放进任一层，另一层就要反向依赖它。
 *
 * 抽样由调用方传入（`random`），于是这条曲线能在不碰网络、不等时间的前提下被断言。
 */
import Foundation

enum StreamBackoff {

    /// 第一次重连的等待上限。
    static let baseMs = 500

    /// 等待的上限 —— 再久就不如让用户看见「连不上」。
    static let maxMs = 10_000

    /// 第 `attempt` 次重连该等多久。
    ///
    /// - Parameters:
    ///   - attempt: 第几次（从 1 起）。小于 1 按 1 算。
    ///   - random: 抖动采样，`0..<1`；实际延迟落在上限的 50%–100%。
    static func delayMs(attempt: Int, random: Double) -> Int {
        let exponent = min(max(attempt, 1), 16) - 1
        let cap = min(baseMs * (1 << exponent), maxMs)
        return Int(Double(cap) * (0.5 + min(max(random, 0), 1) * 0.5))
    }
}
