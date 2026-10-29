/**
 * 组网录入那一段的状态：两份地址、接入密钥、能不能提交、保存并接入。
 *
 * 与 `PairingState` 分开：它们认识的不是同一件事 —— 那一段换的是**身份**（设备凭证），
 * 这一段换的是**路径**（headscale 与网关地址）。失败域也不同：配对失败是服务端拒了那张码，
 * 组网失败是节点起不来。一屏两个状态源，按部件划分。
 *
 * 三条纪律，都对着一段具体的坑：
 * - **构造不读盘**：`@State` 初值每次视图重建都求值，构造里有 I/O 就会在那几次里各留一道
 *   痕迹。盘上的那份由本类的 `adoptStoredFromDisk()` 读 —— 读盘归这一层，视图只决定时机。
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

    /// 最近一次被拒的原因。**只说「因为什么」，说成什么话归 `Display/`** ——
    /// 「能不能提交」与「为什么没提交」是同一件事的两面，分到两处就会出现
    /// 「按钮亮着、点了却什么也没发生」。
    var blockedReason: BlockedReason?

    /// 被拒的原因。与 `MeshActionOutcome.busy` 分开：那个是服务层的回答，
    /// 这个是这一页要讲给用户听的东西（措辞不在这里）。
    enum BlockedReason: Equatable {
        case nodeStarting
    }

    /// 最近一次落盘的那一份。`retryMesh` 用它 —— 重试的是「存下来的配置」，不是草稿。
    private(set) var stored: MeshConfig
    /// 落盘。**注入**是为了让「存的那份与交出去的那份是同一份」能被断言 —— 真写 UserDefaults
    /// 时断言不了，而这条正是最容易写错的：分两次构造就会出现「存的是 A、连的是 B」。
    private let save: (MeshConfig) -> Void
    private let submit: (String, MeshConfig) async -> MeshActionOutcome
    private let retry: (MeshConfig) async -> MeshActionOutcome
    /// 节点此刻是否正在起。只在这一页**动手前**问一次，不参与观察 ——
    /// 说法由可观察的 `blockedReason` 承担，不必让「忙」这个事实再流一遍。
    private let isStarting: () -> Bool

    init(stored: MeshConfig,
         save: @escaping (MeshConfig) -> Void = { $0.save() },
         submit: @escaping (String, MeshConfig) async -> MeshActionOutcome,
         retry: @escaping (MeshConfig) async -> MeshActionOutcome,
         isStarting: @escaping () -> Bool) {
        self.stored = stored
        self.controlURL = stored.controlURLString
        self.gatewayURL = stored.gatewayURLString
        self.save = save
        self.submit = submit
        self.retry = retry
        self.isStarting = isStarting
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
    /// `defaults` 可注入，是为了让「读坏了不填」这一支能被断言 —— 真读 `UserDefaults.standard`
    /// 时造不出损坏态，而它正是这条规则最容易写反的地方。
    func adoptStoredFromDisk(_ defaults: UserDefaults = .standard) {
        if case .ok(let config) = MeshConfig.read(defaults) { adoptStored(config) }
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
    ///
    /// **节点正在起时整条都不做**：服务层会拒掉（`.busy`），而若先把草稿落盘、把密钥
    /// 清空，用户看到的是「保存了」，实际这份密钥从没进过沙盒 —— 它只在这个输入框里
    /// 活过。所以先问一句，把用户的输入原样留着，等接入结束再提交。
    func saveAndConnect() async {
        guard !isStarting() else {
            blockedReason = .nodeStarting
            return
        }
        blockedReason = nil
        let config = self.config
        save(config)
        stored = config
        let key = tailnetKey
        tailnetKey = ""
        if await submit(key, config) == .busy {
            // 预判与提交之间理论上插不进第二条起节点的路（都在 MainActor 上、中间没有
            // 挂起点），但「理论上」不是判据 —— 真被拒了就把钥匙还给用户，别说成功。
            tailnetKey = key
            blockedReason = .nodeStarting
        }
    }

    /// 用存下来的那份配置重试 —— 用户没保存的新草稿不该被偷偷拿去连。
    func retryMesh() async {
        guard !isStarting() else {
            blockedReason = .nodeStarting
            return
        }
        blockedReason = nil
        if await retry(stored) == .busy {
            blockedReason = .nodeStarting
        }
    }
}
