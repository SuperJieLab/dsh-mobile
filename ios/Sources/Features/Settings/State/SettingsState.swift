/**
 * 设置页的依赖面：组网那行的说法与身份（有没有凭证、能不能解除）。
 *
 * **它不认识 `RpcClient`**：身份与解除都以闭包注入。这里不放中文 —— 句子在 `MeshText.swift`。
 */
import Foundation

@MainActor
final class SettingsState {
    /// 节点五态与路径的来源。只读 —— 动手改路径的入口在组网那一页。
    let store: MeshStore

    /// 有没有身份。**闭包而非字段**：闭包里读的是 `CredentialStore.hasDeviceToken`，
    /// 而它可观察 —— 视图求值时读到这里就建立了追踪，凭证一变整页重算。
    private let hasIdentity: () -> Bool
    /// 解除配对。闭包而非客户端：这一层不该知道怎么发请求。
    private let discardIdentity: () -> Void

    init(store: MeshStore,
         hasIdentity: @escaping () -> Bool,
         discardIdentity: @escaping () -> Void) {
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
