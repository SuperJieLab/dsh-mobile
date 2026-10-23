import Foundation

/**
 * 设备凭证的业务包装：它是什么、什么时候落盘、什么时候抹掉。
 *
 * **为什么在网关域而不在 `Core/SecretFile.swift` 那一层。** `SecretFile` 是基建（字节怎么
 * 落到磁盘：路径、权限、原子写、失败留痕），它被两方共用 —— 本类和 `MeshNetwork` 的接入 key。
 * 基建只该有一种，业务包装各随各的域：接入 key 的语义（空串不算 key）住在 `TailnetNode`，
 * 设备凭证的语义（与这台 Mac 的关系）住在这里。把本类塞进那层基建，等于让一个只管字节的
 * 地方去认识「关系」这个概念 —— 那条依赖方向由 `LayeringTests` 的 `coreUpwardBans` 表守着。
 *
 * 设备凭证是**关系本体**：要经得起杀 App / 重启，被撤销才消失。访问票不在这里
 * —— 它是 15 分钟的运行时产物，见 `TicketKeeper`。
 *
 * 存储介质的选择（沙盒文件而非 Keychain / UserDefaults，以及明文可接受的取舍）在
 * `SecretFile` 的文件头，这里不再重复。
 */
@MainActor
final class CredentialStore {

    static let shared = CredentialStore()

    /// 设备凭证落在哪儿。默认是沙盒文件；测试注入内存实现 —— 测试不该写进 App 真正的凭证目录
    /// （那会把模拟器/真机上已经配好的关系覆盖掉，而这类副作用在断言里看不出来）。
    struct Storage {
        var read: () -> String?
        var write: (String) -> Void
        var delete: () -> Void

        static let secretFile = Storage(
            read: { SecretFile.read("device-token") },
            write: { SecretFile.write("device-token", $0) },
            delete: { SecretFile.delete("device-token") }
        )
    }

    private let storage: Storage

    /// 沙盒里存着的设备凭证；没有就是未配对。被撤销时由 `RpcClient` 清掉。
    private(set) var deviceToken: String?

    var hasDeviceToken: Bool { deviceToken != nil }

    init(storage: Storage = .secretFile) {
        self.storage = storage
        self.deviceToken = storage.read()
    }

    func saveDeviceToken(_ token: String) {
        deviceToken = token
        storage.write(token)
    }

    /// 关系在这台手机上的终点：被撤销（换票 401）时由 `RpcClient` 调用。
    ///
    /// 只管设备凭证。手上那张访问票由票那一层自己清 —— 两边各清各的，这个类就不必知道
    /// 世界上有「票」这回事。
    func deleteDeviceToken() {
        deviceToken = nil
        storage.delete()
    }
}
