/**
 * 一次请求可能怎么失败 —— 失败词汇的唯一出处。
 *
 * 住线上形状而不是传输：形状的响应校验要抛它，传输也要抛它；只有「被两边依赖的一侧」能避免
 * 反向依赖。这里只放**词汇**（有哪些失败），不放它怎么被说给用户听 ——
 * 句子与渲染在 `Display/FailureText.swift`。
 */
import Foundation

/// 传输与信封读面的错误：不是协议语义，是「这次请求卡在哪一层」的翻译。
/// 协议内的拒绝走 `.refused(GatewayFailure)`。
enum GatewayClientError: Error {
    /// 请求压根没发出去或没回来 —— 网络层的事，不是协议层的事。
    case transport(url: URL, underlying: Error)
    /// 回来了，但 HTTP 状态不是 200（协议下 400 = body 不是 JSON，413 = body 过大）。
    case badStatus(Int)
    /// 回来了、200，但不是我们能读的报文。
    case malformedResponse(detail: String)
    /// 响应的 `v` 不是本客户端认识的版本。
    case versionMismatch(Int)
    /// 服务端按信封拒绝了。这是**协议内的**结果，不是故障。
    case refused(GatewayFailure)
    /// 没有可用身份：未配对，或设备凭证已被服务端撤销。
    /// 不可重试 —— 重试要靠重新配对，不是再发一次。
    case unauthenticated
    /// 端点不存在：组网尚未激活。零网络 —— 激活后重试即可。
    case notActivated
}
