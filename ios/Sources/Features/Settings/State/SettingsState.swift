/**
 * 设置页的依赖面：组网那一行的说法与身份（有没有凭证、能不能解除）。
 *
 * 它成立的依据是两条**组合**：`meshSummary` 把阶段与路径拼成一句副标题，
 * `identitySummary` 把「有没有凭证」翻成一句状态。零组合的容器是转发层。
 *
 * **它不认识 `RpcClient`。** 身份与解除都以闭包注入 —— 视图拿到客户端就知道怎么发请求，
 * 那是禁的；而这一层也不需要知道。闭包的另一端在组合根。
 *
 * **引用 ≠ 拥有**：`setup` / `store` 是根造的、与进程同寿。解除配对会清掉沙盒里的设备
 * 凭证与在手票 —— 那是身份与票自己的事，不由这一层执行。
 *
 * 这里不放中文：组网那行的句子在 `MeshSettings/Display/MeshText.swift`。
 */
import Foundation

@MainActor
final class SettingsState {
    /// 组网录入（地址、接入密钥、保存并接入）—— 设置页把它转交给组网配置页。
    let setup: MeshSetupState
    /// 节点五态与路径的来源。只读 —— 动手的入口在 `setup`。
    let store: MeshStore

    /// 有没有身份。**闭包而非字段**：闭包里读的是 `CredentialStore.hasDeviceToken`，
    /// 而它可观察 —— 视图求值时读到这里就建立了追踪，凭证一变整页重算。
    private let hasIdentity: () -> Bool
    /// 解除配对。闭包而非客户端：这一层不该知道怎么发请求。
    private let discardIdentity: () -> Void

    init(setup: MeshSetupState,
         store: MeshStore,
         hasIdentity: @escaping () -> Bool,
         discardIdentity: @escaping () -> Void) {
        self.setup = setup
        self.store = store
        self.hasIdentity = hasIdentity
        self.discardIdentity = discardIdentity
    }

    /// 有没有身份。读穿到闭包 —— 它翻假时这一页会自动重算。
    var isPaired: Bool { hasIdentity() }

    /// 组网那一行的副标题：阶段 + 路径（就绪时）。
    var meshSummary: String {
        let phase = store.phase
        guard case .ready = phase else { return meshPhaseText(phase) }
        return carrierPathText(store.meshPath).map { "\(meshPhaseText(phase)) · \($0)" }
            ?? meshPhaseText(phase)
    }

    /// 解除配对：清掉本地凭证与在手票。服务端那边由 Mac 侧撤销，这里只管本机。
    func unlink() {
        discardIdentity()
    }
}
