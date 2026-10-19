import Foundation

/**
 * 三张票在手机侧的家。
 *
 * 设备凭证是关系的本体，要经得起杀 App / 重启（进 App 沙盒）；访问凭证只是 15 分钟的时间片，
 * 丢了就换（只进内存）—— 时间片不是资产。
 *
 * 存储：`SecretFile`，Application Support/secrets/ 下的自管文件，complete 文件保护。不用
 * Keychain 是因为它跨卸载存活、与「卸载即失效」冲突；不用 UserDefaults 是因为语义是偏好设置。
 * 个人设备上文件内明文可接受 —— 攻击者能读这个文件时，同机的 Keychain 也护不住什么。
 *
 * 单例：全 App 只有一个身份。`GatewayClient` 签发与续期，`FollowClient` 升级时读。
 */
@MainActor
final class CredentialStore {

    static let shared = CredentialStore()

    // MARK: - 设备凭证（关系本体，沙盒文件）

    /// 沙盒里存着的设备凭证；没有就是未配对。被撤销时由续期失败清掉。
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
