import Foundation

/**
 * 密钥与令牌的**落盘基建**：一个字符串按名字存进 App 沙盒，或读出来、删掉。
 * 只管字节怎么落地 —— 路径、目录创建、原子写、`complete` 文件保护、失败留痕。
 * 不用 UserDefaults（全局键值命名空间、语义是偏好设置）、不用 Keychain（跨卸载存活）。
 * 写/删失败不允许静默 ——「配对成功但凭证没落盘」会表现为下次启动回到未配对态。
 */
enum SecretFile {

    /// read 的缺席是常态（未配对），不记日志；读到但解不出 UTF-8 属损坏，按缺席处理。
    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ name: String, _ value: String) {
        do {
            try FileManager.default.createDirectory(at: baseURL(), withIntermediateDirectories: true)
            guard let data = value.data(using: .utf8) else {
                Log.error(Log.Module.gateway, "SecretFile: 不是合法 UTF-8，未落盘", ["name": name])
                return
            }
            try data.write(to: url(name), options: [.atomic, .completeFileProtection])
        } catch {
            Log.error(Log.Module.gateway, "SecretFile: 写失败",
                    ["name": name, "error": error.localizedDescription])
        }
    }

    static func delete(_ name: String) {
        do {
            try FileManager.default.removeItem(at: url(name))
        } catch let error as NSError where error.code != NSFileNoSuchFileError && error.domain == NSCocoaErrorDomain {
            Log.warn(Log.Module.gateway, "SecretFile: 删失败",
                   ["name": name, "error": error.localizedDescription])
        } catch {
            // 文件本来就不在：删除的幂等终态，不算事。
        }
    }

    private static func baseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("secrets", isDirectory: true)
    }

    private static func url(_ name: String) -> URL {
        baseURL().appendingPathComponent(name)
    }
}
