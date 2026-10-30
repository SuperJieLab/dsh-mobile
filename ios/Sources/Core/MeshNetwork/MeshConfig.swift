/**
 * 组网配置：控制面地址 + 网关 tailnet 地址。
 *
 * **控制面留空 = 官方 Tailscale**（`controlURLDefault`）。自建 headscale 才需要填地址，
 * 它内嵌 VPS 公网 IP 而仓库是公开的 —— 那种真实值只存在于设备本地与用户输入时刻。
 * 网关地址没有默认值：官方与自建分配的 100.x 都不可预测，填错了只会把失败伪装成
 * 「服务不可达」，所以宁可让它空着逼人填。读写都不许静默失败：「存过但读不出来」与
 * 「从来没配过」是两件事。
 */
import Foundation

struct MeshConfig: Equatable, Codable {
    /// 控制面地址，如 `https://<VPS-IP>:8443`；**空串表示用官方 Tailscale**。
    var controlURLString: String
    /// Mac 网关的 tailnet 地址（直用 100.x IP，不用 MagicDNS）。
    var gatewayURLString: String

    /// 控制面留空时落到的地址，与 libtailscale 的 `kDefaultControlURL` 同值。
    /// 它只回答「不填时连哪」，不代表官方是唯一路 —— 自建仍然是填地址那条。
    static let controlURLDefault = "https://controlplane.tailscale.com"

    /// 「从没配过」的形状：两格都空。`isComplete` 因此为假（缺网关地址）。
    ///
    /// 它是一个值而不是一次读盘 —— 需要「还没配」这个起点的调用方拿它，不必碰磁盘。
    static let unconfigured = MeshConfig(controlURLString: "", gatewayURLString: "")

    /// 能不能拿去连：控制面（空 = 官方）是 https，且网关地址填了。
    /// **它不回答「配没配过」** —— 那件事由「有没有接入密钥」回答（`TailnetNode.launch`）。
    var isComplete: Bool {
        controlURL?.scheme == "https" && gatewayBaseURL?.scheme != nil
    }

    /// 归一后的控制面。**空串在这里变成官方地址**：读它的只有 `isComplete` 与
    /// `TailnetNode`，归一放在取值上，这两处就不会各自解释一遍空串。
    var controlURL: URL? {
        URL(string: controlURLString.isEmpty ? Self.controlURLDefault : controlURLString)
    }

    var gatewayBaseURL: URL? { URL(string: gatewayURLString) }

    // MARK: - UserDefaults 持久化（App 沙盒本地，不进仓库）

    /// 读盘的结果 —— **三态，不是「配置或默认值」**。
    /// `damaged` 必须单独存在：并进 `missing` 会让「存过但坏了」表现成「干净首启」。
    enum ReadOutcome: Equatable {
        /// 从来没配过：键不存在，干净首启。
        case missing
        /// 键在，但解不出来（旧格式 / 外部写入 / 迁移失败）。已留痕。
        case damaged
        case ok(MeshConfig)
    }

    private static let defaultsKey = "mesh.config.v1"

    static func read(_ defaults: UserDefaults = .standard) -> ReadOutcome {
        guard let raw = defaults.string(forKey: defaultsKey) else { return .missing }
        guard let data = raw.data(using: .utf8),
              let config = try? JSONDecoder().decode(MeshConfig.self, from: data) else {
            Log.error(Log.Module.mesh, "mesh config damaged — stored bytes cannot be decoded")
            return .damaged
        }
        return .ok(config)
    }

    /// 写入。编不出来就留痕 —— 静默失败会让界面显示新值、节点用旧值。
    func save(_ defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(self)
            guard let text = String(data: data, encoding: .utf8) else {
                Log.error(Log.Module.mesh, "mesh config not saved — encoding is not UTF-8")
                return
            }
            defaults.set(text, forKey: Self.defaultsKey)
        } catch {
            Log.error(Log.Module.mesh, "mesh config not saved: \(error.localizedDescription)")
        }
    }
}
