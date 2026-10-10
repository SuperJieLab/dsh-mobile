/**
 * 组网配置：headscale 控制面地址 + 网关 tailnet 地址。
 *
 * 为什么不在源码里硬编码：controlURL 内嵌 VPS 公网 IP（隐私纪律 —— 仓库是公开的，
 * 真实值只存在于设备本地 UserDefaults 与用户输入时刻）；gateway 地址是 tailnet 内的
 * CGNAT 段 IP，出了网没有意义，给默认值（沿用「硬编码一行」的先例）。
 *
 * 改动入口在设置页（PairingView 的组网段）；换 VPS/换 IP = 改这里 + 重装信任证书。
 */
import Foundation

struct MeshConfig: Equatable, Codable {
    /// headscale 控制面，如 `https://<VPS-IP>:8443`。
    var controlURLString: String
    /// Mac 网关的 tailnet 地址（直用 100.x IP，不用 MagicDNS）。
    var gatewayURLString: String

    static let gatewayDefault = "http://100.64.0.1:3081"

    /// 设置页可直接用：controlURL 为空 = 还没配过。
    var isComplete: Bool {
        URL(string: controlURLString)?.scheme == "https"
            && URL(string: gatewayURLString)?.scheme != nil
    }

    var controlURL: URL? { URL(string: controlURLString) }
    var gatewayBaseURL: URL? { URL(string: gatewayURLString) }

    // MARK: - UserDefaults 持久化（App 沙盒本地，不进仓库）

    private static let defaultsKey = "mesh.config.v1"

    static func load(_ defaults: UserDefaults = .standard) -> MeshConfig {
        if let raw = defaults.string(forKey: defaultsKey),
           let data = raw.data(using: .utf8),
           let config = try? JSONDecoder().decode(MeshConfig.self, from: data) {
            return config
        }
        return MeshConfig(controlURLString: "", gatewayURLString: gatewayDefault)
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(String(data: data, encoding: .utf8), forKey: Self.defaultsKey)
    }
}
