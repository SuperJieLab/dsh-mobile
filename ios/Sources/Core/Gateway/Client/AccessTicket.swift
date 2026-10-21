import Foundation

/**
 * 一次「要一张访问票」的结果。
 *
 * **三态，不是两态。** 两态（有 / 没有）会把三种处境说成一句话，而它们要的处置完全不同：
 *
 * | 结果 | 什么时候 | 使用方该做什么 |
 * |---|---|---|
 * | `.granted` | 手上有票，或刚换到 | 用它 |
 * | `.unavailable` | 未配对；或关系被服务端撤销（401） | **停**。没有用户动作不会变，重试只是空转 |
 * | `.retryLater` | 网络不通、网关不在、换票这次失败 | **等**。退避后再试，状态没坏 |
 *
 * 混成一个 `Bool` 的后果是具体的：退避重连那条路会对着 `.unavailable` 无限重试，
 * 每 10 秒一次、静默、永不收敛；而 HTTP 那边会把「网络不通」报成「未配对，请重新配对」，
 * 让人去查一件没发生的事。
 *
 * 与 `GatewayErrorCode` 的分工：那边是**协议**的拒绝词汇（线上有什么码），这边是
 * **身份**的三种处境。收不出票的原因可能压根没经过协议（未配对在本地就结束了）。
 */
enum AccessTicket: Equatable {
    /// 一张还活着的票。
    case granted(String)
    /// 拿不到，且**不会自己好** —— 需要用户去配对，或解释关系已被撤销。
    case unavailable
    /// 这次拿不到，但状态没有坏 —— 等一会儿再来。
    case retryLater

    /// 手上的票本身（只有 `.granted` 才有）。
    var token: String? {
        guard case .granted(let token) = self else { return nil }
        return token
    }
}
