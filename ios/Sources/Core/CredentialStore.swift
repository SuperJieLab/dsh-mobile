import Foundation

/**
 * 三张票在手机侧的家（M4）。
 *
 * 设备凭证是关系的本体，要经得起杀 App / 重启（进 App 沙盒）；访问凭证只是 15 分钟的
 * 时间片，丢了就换（只进内存）—— 与「客户端不落盘位置」同一条纪律：时间片不是资产。
 *
 * 存储位置（M8 后注，原为 Keychain → UserDefaults → 沙盒文件）：`SecretFile`，
 * Application Support/secrets/ 下自管文件，complete 文件保护。Keychain 跨卸载存活
 * 且无法随卸载清除，与「卸载即失效」冲突；UserDefaults 语义是偏好设置、存凭证名不
 * 正言顺。个人设备场景下文件内明文可接受，论证见 `docs/dev/plans/M8-cross-network.md` §后注。
 *
 * 单例：全 App 只有一个身份。`GatewayClient` 签发与续期，`FollowClient` 升级时读。
 */
@MainActor
final class CredentialStore {

    static let shared = CredentialStore()

    // MARK: - 设备凭证（关系本体，沙盒文件）

    /// 沙盒里存着的设备凭证；没有就是未配对。被撤销时由续期失败清掉。
    /// （Keychain 时代的旧条目已由 M8 迁移期的 purgeLegacyKeychain 清空，该尾款已撤。）
    private(set) var deviceToken: String? = SecretFile.read("device-token")

    var hasDeviceToken: Bool { deviceToken != nil }

    func saveDeviceToken(_ token: String) {
        deviceToken = token
        SecretFile.write("device-token", token)
    }

    /// 关系在这台手机上的终点：被撤销（续期 401）时由 `GatewayClient` 调用。
    func deleteDeviceToken() {
        deviceToken = nil
        clearAccess()
        SecretFile.delete("device-token")
    }

    // MARK: - 访问凭证（时间片，只进内存）

    private var accessToken: String?
    private var accessExpiresAt = Date.distantPast

    /// 还活着才给 —— 过期的票等价于没有票，调用方走续期。
    func validAccessToken(now: Date = Date()) -> String? {
        guard let accessToken, now < accessExpiresAt else { return nil }
        return accessToken
    }

    func storeAccess(_ token: String, expiresAt: Date) {
        accessToken = token
        accessExpiresAt = expiresAt
    }

    private func clearAccess() {
        accessToken = nil
        accessExpiresAt = .distantPast
    }
}
