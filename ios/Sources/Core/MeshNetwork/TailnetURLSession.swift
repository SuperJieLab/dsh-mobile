/**
 * 网关流量的传输：URLSession 经 `proxyConfigurations` 走节点内建的
 * SOCKS5 回环代理。代理发现、凭证、配置拼接全部用上游自己的
 * `URLSessionConfiguration.tailscaleSession(_:)`（swift/TailscaleKit/URLSession+Tailscale.swift）——
 * 我们不手拼 `ProxyConfiguration`，上游形状漂移在这里失败，不会带到真机。
 *
 * 消息层（GatewayClient / FollowClient）对这只 session 无感知：iOS 17+ 起
 * `URLSessionWebSocketTask` 也会遵守 `proxyConfigurations`。
 */
import Foundation
import TailscaleKit

enum TailnetURLSession {
    /// 建一只把全部流量送进 tailnet 的 URLSession。必须在节点 `up()` 成功后调用。
    static func makeSession(for node: TailscaleNode) async throws -> URLSession {
        let (configuration, _) = try await URLSessionConfiguration.tailscaleSession(node)
        return URLSession(configuration: configuration)
    }
}
