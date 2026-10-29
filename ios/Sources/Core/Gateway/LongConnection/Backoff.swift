/**
 * 重连延迟：指数爬升、抖动 50–100%、封顶。
 *
 * 整条连接的重连与单条流的重试都问同一个问题（「第 n 次失败之后等多久」），所以曲线只有这一份。
 * 抽样由调用方传入（`random`），于是它能在不碰网络、不等时间的前提下被断言。
 */
import Foundation

enum Backoff {

    /// 第一次重连的等待上限。
    static let baseMs = 500

    /// 等待的上限 —— 再久就不如让用户看见「连不上」。
    static let maxMs = 10_000

    /// 第 `attempt` 次重连该等多久。指数封在 16（再往上也是 `maxMs`），延迟落在上限的 50%–100%。
    static func delayMs(attempt: Int, random: Double) -> Int {
        let exponent = min(max(attempt, 1), 16) - 1
        let cap = min(baseMs * (1 << exponent), maxMs)
        return Int(Double(cap) * (0.5 + min(max(random, 0), 1) * 0.5))
    }
}
