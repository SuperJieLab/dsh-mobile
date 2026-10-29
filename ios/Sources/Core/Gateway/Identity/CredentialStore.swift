import Foundation

/**
 * 设备凭证的业务包装：它是什么、什么时候落盘、什么时候抹掉。
 * 接口是「一个名字 + 一段字节」（`SecretFile`），语义在这里：哪些字节能当凭证、删了意味着
 * **它是「有没有配对」的唯一出处** —— 不要在任何别处存一份 `isPaired`。
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

    /// 身份**刚变过**的那一刻 —— 供编排层接（配对成功后拉起连接）。
    /// 与 `hasDeviceToken` 的分工同 `MeshStore.onPhaseReady`：那个回答「现在有没有」，
    /// **不参与观察**：它是接线不是状态，标上 `@ObservationIgnored` 免得视图白重算一次。
    @ObservationIgnored var onIdentityChanged: (() -> Void)?

    init(storage: Storage = .secretFile) {
        self.storage = storage
        self.deviceToken = storage.read()
    }

    /// 存下配对拿到的设备凭证。
    /// **同一个值再存一次什么都不做**（连写盘一起跳过）：与 `deleteDeviceToken` 的守卫对称。
    /// 代价是盘上内容被外部改动时修不回来 —— 本文件只有本进程一个写者，不需要那条路径。
    func saveDeviceToken(_ token: String) {
        guard token != deviceToken else { return }
        deviceToken = token
        storage.write(token)
        onIdentityChanged?()
    }

    /// 关系在这台手机上的终点：被撤销（换票 401）时由 `RpcClient` 调用。
    ///
    /// 只管设备凭证。手上那张访问票由票那一层自己清 —— 两边各清各的，这个类就不必知道
    /// 世界上有「票」这回事。
    func deleteDeviceToken() {
        guard deviceToken != nil else { return }
        deviceToken = nil
        storage.delete()
        // 只在**真的变过**时通知：撤销是幂等的，重复通知会让编排层重走一遍
        // 「无身份」那几步，而那些步骤的闸都在下游，白跑一趟。
        onIdentityChanged?()
    }
}
