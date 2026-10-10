import Foundation

/**
 * 凭证的沙盒文件存储（M8 后注修订二：UserDefaults → 自管文件）。
 *
 * UserDefaults 也在沙盒里、卸载同样蒸发，但它是全局键值命名空间，语义是「偏好
 * 设置」，存凭证名不正言不顺（还容易留着调试残渣）。凭证收进 Application Support
 * 下自己的目录：权限明确（complete 文件保护 = 锁屏即密文）、可单独检视与删除。
 */
enum SecretFile {

    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ name: String, _ value: String) {
        try? FileManager.default.createDirectory(at: baseURL(), withIntermediateDirectories: true)
        guard let data = value.data(using: .utf8) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtection])
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    private static func baseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("secrets", isDirectory: true)
    }

    private static func url(_ name: String) -> URL {
        baseURL().appendingPathComponent(name)
    }
}
