import Foundation

/**
 * 密钥与令牌的**落盘基建**：把一个字符串按名字存进 App 沙盒，或读出来、删掉。
 *
 * 只管字节怎么落地 —— 路径、目录创建、原子写、`complete` 文件保护、失败留痕。**不认识
 * 任何一个具体的凭证**：哪个名字、内容什么语义、什么时候该删，由各自的业务包装决定
 * （设备凭证在 `Core/Gateway/Rpc/CredentialStore.swift`，组网接入 key 在
 * `MeshNetwork/TailnetNode.swift`）。正因为两边都要用，它才落在 `Core/` 顶层 ——
 * 不属于任何一方，也就没有哪个域能在这里继续长出自己的概念。
 *
 * 存储选型：UserDefaults 也在沙盒里、卸载同样蒸发，但它是全局键值命名空间，语义是「偏好
 * 设置」，存密钥名不正言不顺（还容易留着调试残渣）。不用 Keychain 是因为它跨卸载存活、
 * 与「卸载即失效」冲突。凭证收进 Application Support 下自己的目录：权限明确（complete 文件
 * 保护 = 锁屏即密文）、可单独检视与删除。个人设备上文件内明文可接受 —— 攻击者能读这个
 * 文件时，同机的 Keychain 也护不住什么。
 *
 * 写/删失败不允许静默（降级必须留痕）——「配对成功但凭证没落盘」会
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
