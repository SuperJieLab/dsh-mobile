import Foundation

/**
 * 凭证的沙盒文件存储（Application Support/secrets/ 下自管文件）。
 *
 * UserDefaults 也在沙盒里、卸载同样蒸发，但它是全局键值命名空间，语义是「偏好
 * 设置」，存凭证名不正言不顺（还容易留着调试残渣）。凭证收进 Application Support
 * 下自己的目录：权限明确（complete 文件保护 = 锁屏即密文）、可单独检视与删除。
 *
 * 写/删失败不允许静默（规范 §2.3：降级必须留痕）——「配对成功但凭证没落盘」会
 * 表现为下次启动回到未配对态，没有日志就无从排查。
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
                Log.error(Log.Module.gateway, "SecretFile: \(name) 不是合法 UTF-8，未落盘")
                return
            }
            try data.write(to: url(name), options: [.atomic, .completeFileProtection])
        } catch {
            Log.error(Log.Module.gateway, "SecretFile: 写 \(name) 失败：\(error.localizedDescription)")
        }
    }

    static func delete(_ name: String) {
        do {
            try FileManager.default.removeItem(at: url(name))
        } catch let error as NSError where error.code != NSFileNoSuchFileError && error.domain == NSCocoaErrorDomain {
            Log.warn(Log.Module.gateway, "SecretFile: 删 \(name) 失败：\(error.localizedDescription)")
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
