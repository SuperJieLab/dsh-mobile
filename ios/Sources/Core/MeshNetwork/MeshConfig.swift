/**
 * 组网配置：headscale 控制面地址 + 网关 tailnet 地址。
 *
 * controlURL 不硬编码：它内嵌 VPS 公网 IP，而仓库是公开的 —— 真实值只存在于设备本地与用户
 * 输入时刻。读写都不许静默失败：「存过但读不出来」与「从来没配过」是两件事。
 */
import Foundation

struct MeshConfig: Equatable, Codable {
    /// headscale 控制面，如 `https://<VPS-IP>:8443`。
    var controlURLString: String
    /// Mac 网关的 tailnet 地址（直用 100.x IP，不用 MagicDNS）。
    var gatewayURLString: String

    static let gatewayDefault = "http://100.64.0.1:3081"

    /// 「从没配过」的形状：控制面地址空、网关地址给默认。`isComplete` 因此为假。
    ///
    /// 它是一个值而不是一次读盘 —— 需要「还没配」这个起点的调用方拿它，不必碰磁盘。
    static let unconfigured = MeshConfig(controlURLString: "", gatewayURLString: gatewayDefault)

    /// 设置页可直接用：controlURL 为空 = 还没配过。
    var isComplete: Bool {
        URL(string: controlURLString)?.scheme == "https"
            && URL(string: gatewayURLString)?.scheme != nil
    }

    var controlURL: URL? { URL(string: controlURLString) }
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
