/**
 * 组网录入那一段的状态：两份地址、接入密钥、能不能提交、保存并接入。
 *
 * 与 `PairingState` 分开：它们认识的不是同一件事 —— 那一段换的是**身份**（设备凭证），
 * 这一段换的是**路径**（headscale 与网关地址）。失败域也不同：配对失败是服务端拒了那张码，
 * 组网失败是节点起不来。一屏两个状态源，按部件划分。
 *
 * 三条纪律，都对着一段具体的坑：
 * - **构造不读盘**：`@State` 初值每次视图重建都求值，构造里有 I/O 就会在那几次里各留一道
 *   痕迹。盘上的那份由调用方读到之后经 `adoptStored` 填进来。
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

    init(stored: MeshConfig,
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

    /// 把盘上读到的那份填进来。**读盘不在这里**：构造必须能重入，而 `@State` 的初值表达式
    /// 每次视图重建都求值一次 —— 构造里读盘会在那几次里各留一道痕迹。
    ///
    /// 无条件覆盖两格。适用前提是**调用时机在用户能输入之前**（这一屏刚建好时）：草稿的生命
    /// 周期短于「用户动手」，所以那一刻盘上那份永远是最新的。
    /// 若将来要在从别处返回时重读，这条前提就破了，得改成「只在用户没动过时填」——
    /// 而那时不能再按「格子里有没有字」判，因为起点那份自带一个非空的网关默认值。
    func adoptStored(_ config: MeshConfig) {
        stored = config
        controlURL = config.controlURLString
        gatewayURL = config.gatewayURLString
    }

    /// 读一次盘，把那两份地址填进草稿。读坏了不填 —— 提示由 `store.storedConfigDamaged` 给。
    ///
    /// **读盘归这一层**：视图层（含装配段）不碰持久化类型，它只决定「什么时候读」。
    func adoptStoredFromDisk() {
        if case .ok(let config) = MeshConfig.read() { adoptStored(config) }
    }

    /// 现在这份输入构成的配置。地址与密钥是两段输入，合成一份才算「要连什么」。
    var config: MeshConfig {
        MeshConfig(controlURLString: controlURL, gatewayURLString: gatewayURL)
    }

    /// 可提交吗 —— 两个条件都是现成的判定：接入密钥非空，且两份地址构成完整配置。
    ///
    /// 就地判而不另立规则类型：它没有独立于这两个判定的决定。
    var canSubmit: Bool {
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
