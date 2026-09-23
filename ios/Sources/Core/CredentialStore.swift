import Foundation
import Security

/// Keychain 条目的公共字段 —— 文件级函数：读设备凭证发生在实例属性初始化器里，
/// 那时 `self` 与 `Self` 都不可用。
private func keychainQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dsh-mobile.device-token",
        kSecAttrAccount as String: "device",
    ]
}

/**
 * 三张票在手机侧的家（M4）。
 *
 * 设备凭证是关系的本体，要经得起杀 App / 重启（进 Keychain）；访问凭证只是 15 分钟的
 * 时间片，丢了就换（只进内存）—— 与「客户端不落盘位置」同一条纪律：时间片不是资产。
 *
 * 单例：全 App 只有一个身份。`GatewayClient` 签发与续期，`FollowClient` 升级时读。
 */
@MainActor
final class CredentialStore {

    static let shared = CredentialStore()

    // MARK: - 设备凭证（关系本体，Keychain）

    /// Keychain 里存着的设备凭证；没有就是未配对。重装 App 后 Keychain 仍在，
    /// 所以「未配对」的判定以能读到为准；被撤销时由续期失败清掉。
    private(set) var deviceToken: String? = {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }()

    var hasDeviceToken: Bool { deviceToken != nil }

    func saveDeviceToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        deviceToken = token

        // 已有则更新，没有则新增 —— Keychain 的两步写，没有 upsert。
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(keychainQuery() as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var add = keychainQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 关系在这台手机上的终点：被撤销（续期 401）时由 `GatewayClient` 调用。
    func deleteDeviceToken() {
        deviceToken = nil
        clearAccess()
        SecItemDelete(keychainQuery() as CFDictionary)
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
