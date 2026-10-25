/**
 * 网关在哪、走哪条路 —— **两条链路共用的唯一持有者**。
 *
 * 它只认识两个值：一个地址、一条传输。不认识票、不认识流、不认识协议错误码 ——
 * 所以它可以被 HTTP 出口与 WebSocket 建连同时读，而不让两者互相认识。
 *
 * **为什么是对象而不是值类型**：`update` 由组网激活在运行时调用（节点验证 Running 之后），
 * 而读它的是两条链路各自的建连路径。值类型会在传递中复制出各自为政的副本 ——
 * 症状是「切了组网仍往老地址打」，只在真机上表现为连不上，本地全绿。
 * 这与 `CredentialStore` 从 `struct` 改 `class` 是同一个理由：可变共享状态不能按值传。
 *
 * **为什么地址与传输要住在一起**：它们由同一件事共同决定（组网激活），且总是一起变。
 * 分开就会出现「换了地址没换传输」这类中间态。
 */
import Foundation

@MainActor
final class Endpoint {

    /// 网关端点 —— **激活前不存在**：App 在节点验证 Running 之前不持有任何网关地址。
    /// 它是「该往哪打」的唯一事实，读者不该缓存副本。
    private(set) var baseURL: URL?

    /// 激活后换上的传输：激活前 = `.shared`（但端点不存在，请求不会发出）。
    /// 两条链路每次建连/发请求都现取 —— 激活后下一轮即走隧道。
    private(set) var session: URLSession = .shared

    /// 组网通了：从此往这里打、走这条路。**唯一写入点。**
    ///
    /// 名字说的是「把这两个值换成新的」，不冒充「激活」—— 组网是否算激活由
    /// `MeshStore` 判断（它有节点状态机），这里只负责存。
    func update(session: URLSession, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
        Log.info(Log.Module.gateway, "endpoint updated → \(baseURL.absoluteString)")
    }
}
