/**
 * 上游 tsnet 的窄面 —— **本仓只经这一个文件认识 TailscaleKit**。
 *
 * 这一层不是「为了整洁」，是为了让两条判据写得出来：`TailnetNode` 的接入口径里有两条只有
 * 「让 `up()` 挂住」才构造得出（接入途中不探活 / 接入窗口靠 `defer` 进出）。上游
 * `TailscaleNode` 是 actor，`TailnetNode` 里直接 new 真件 ⇒ 那两条只能靠真机日志。
 * 把「起、关、读状态、建 session」抽出来，假件就替得进去。
 *
 * **四个方法不是四件事，是两条判据的最低代价**：少掉「建 session」，`up()` 就走不到成功
 * 路径，正控写不成 —— 只剩负控时，把 `revive()` 写成空函数也是绿的。
 *
 * 入参用四个字段而不是上游的 `Configuration`：测试因此不必 import 上游类型。
 */
import Foundation
import TailscaleKit

/// 上游节点的四个能力。假件只需要这四个。
protocol TailnetBackend: Sendable {
    /// 等登录完成。key 错误从这里冒出；**没有自己的超时**（超时是 `TailnetNode` 的策略）。
    func up() async throws
    /// 上游给出的唯一取消手段 —— 卡住的 `up()` 只能靠它收尾。
    func close() async throws
    /// 读 `tailscale status --json` 的原始字节。后端事实（`BackendState` / 对端路径）只从这儿来。
    func statusJSON() async throws -> Data
    /// 建一只全部流量走 tailnet 的 session。真件在 `up()` 成功之后调用才有意义。
    func makeGatewaySession() async throws -> URLSession
}

/// 造一个后端要的四个输入。**不是**上游的 `Configuration` —— 那一层只在 `live` 里出现一次。
struct TailnetBackendSpec: Sendable {
    let hostName: String
    let stateDir: String
    let authKey: String?
    let controlURL: String
}

/// 默认造真件，测试注入假件。
typealias BackendFactory = @Sendable (TailnetBackendSpec) throws -> any TailnetBackend

enum TailnetBackends {

    /// 生产实现。`TailscaleNode` 的构造即 `tailscale_start` —— 抛错发生在这一步（状态目录
    /// 不可写等），而归因在 `TailnetNode` 里按错误消息做。
    static let live: BackendFactory = { spec in
        try TailscaleNode(
            config: Configuration(
                hostName: spec.hostName,
                path: spec.stateDir,
                authKey: spec.authKey,
                controlURL: spec.controlURL
            ),
            logger: nil
        )
    }
}

extension TailscaleNode: TailnetBackend {

    func makeGatewaySession() async throws -> URLSession {
        try await TailnetURLSession.makeSession(for: self)
    }
}

// MARK: - 网关流量的传输

/**
 * 网关流量的传输：URLSession 经 `proxyConfigurations` 走节点内建的
 * SOCKS5 回环代理。代理发现、凭证、配置拼接全部用上游自己的
 * `URLSessionConfiguration.tailscaleSession(_:)`（swift/TailscaleKit/URLSession+Tailscale.swift）——
 * 我们不手拼 `ProxyConfiguration`，上游形状漂移在这里失败，不会带到真机。
 *
 * 消息层（RpcClient / WebSocketConnection）对这只 session 无感知：iOS 17+ 起
 * `URLSessionWebSocketTask` 也会遵守 `proxyConfigurations`。
 *
 * 住在这个文件里而不是单独一个：它唯一的入参是上游节点，把它留在别处就得让第二个文件
 * `import TailscaleKit` —— 上游类型的引用面会从一处变两处。
 */
enum TailnetURLSession {
    /// 建一只把全部流量送进 tailnet 的 URLSession。必须在节点 `up()` 成功后调用。
    static func makeSession(for node: TailscaleNode) async throws -> URLSession {
        let (configuration, _) = try await URLSessionConfiguration.tailscaleSession(node)
        return URLSession(configuration: configuration)
    }
}
