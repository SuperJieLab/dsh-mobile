import Foundation

/**
 * 设备凭证的业务包装：它是什么、什么时候落盘、什么时候抹掉。
 *
 * **接口是「一个名字 + 一段字节」**（`SecretFile`），语义在这里：哪些字节能当凭证、什么时候
 * 该删、删了意味着什么。接入 key 同样，只是它的语义住在 `TailnetNode`。
 *
 * 设备凭证是**关系本体**：要经得起杀 App / 重启，被撤销才消失。访问票不在这里 ——
 * 它是 15 分钟的运行时产物，见 `TicketKeeper`。
 *
 * **它是「有没有配对」的唯一出处。** 不要在任何别处存一份 `isPaired` ——「已配对 ≡ 有凭证」
 * 是结构，不是靠手工同步维持的纪律。
 */
@MainActor
@Observable
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
