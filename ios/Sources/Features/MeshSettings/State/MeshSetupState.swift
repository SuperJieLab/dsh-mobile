/**
 * 组网录入那一段的状态：两份地址、接入密钥、能不能提交、保存并接入。
 *
 * 与 `PairingState` 分开：它们认识的不是同一件事 —— 那一段换的是**身份**（设备凭证），
 * 这一段换的是**路径**（headscale 与网关地址）。失败域也不同：配对失败是服务端拒了那张码，
 * 组网失败是节点起不来。一屏两个状态源，按部件划分。
 *
 * 三条纪律，都对着一段具体的坑：
 * - **构造时读一次盘**，不是每次视图重建读一次 —— 视图的 `@State` 初值每次重建都求值。
 * - **同一份 `config` 既落盘又交给连接域**：分两次构造会出现「存的是 A、连的是 B」。
 * - **`tailnetKey` 先捕获再清空**：提交是异步的，顺序反了提交的永远是空串。
 *
 * 持久化与「提交给谁」都在这里，视图只读值、调无参方法 —— 它不认识 `MeshConfig`，
 * 也碰不到磁盘。
 */
import Foundation

@MainActor
@Observable
final class MeshSetupState {

    var controlURL: String
    var gatewayURL: String
    /// 明文输入（用户要求：key 要看得见才敢确认贴对了）。提交成功即清空。
    var tailnetKey = ""

    /// 最近一次落盘的那一份。`retryMesh` 用它 —— 重试的是「存下来的配置」，不是草稿。
    private(set) var stored: MeshConfig
    /// 落盘。**注入**是为了让「存的那份与交出去的那份是同一份」能被断言 —— 真写 UserDefaults
    /// 时断言不了，而这条正是最容易写错的：分两次构造就会出现「存的是 A、连的是 B」。
    private let save: (MeshConfig) -> Void
    private let submit: (String, MeshConfig) async -> Void
    private let retry: (MeshConfig) async -> Void

    init(stored: MeshConfig = MeshConfig.load(),
         save: @escaping (MeshConfig) -> Void = { $0.save() },
         submit: @escaping (String, MeshConfig) async -> Void,
         retry: @escaping (MeshConfig) async -> Void) {
        self.stored = stored
        self.controlURL = stored.controlURLString
        self.gatewayURL = stored.gatewayURLString
        self.save = save
        self.submit = submit
        self.retry = retry
    }

    /// 现在这份输入构成的配置。地址与密钥是两段输入，合成一份才算「要连什么」。
    var config: MeshConfig {
        MeshConfig(controlURLString: controlURL, gatewayURLString: gatewayURL)
    }

    /// 可提交吗 —— 一行转发到 `PairingRules`（同屏的两条规则住同一个值类型）。
    var canSubmit: Bool {
        // 两个条件都是现成的判定：接入密钥非空，且两份地址构成完整配置。
        // 写在这里而不另立一个规则类型 —— 它没有独立于这两个判定的决定。
        !tailnetKey.isEmpty && config.isComplete
    }

    /// 保存并接入：先落盘，再把**同一份**配置交给连接域。
    func saveAndConnect() async {
        let config = self.config
        save(config)
        stored = config
        let key = tailnetKey
        tailnetKey = ""
        await submit(key, config)
    }

    /// 用存下来的那份配置重试 —— 用户没保存的新草稿不该被偷偷拿去连。
    func retryMesh() async {
        await retry(stored)
    }
}
