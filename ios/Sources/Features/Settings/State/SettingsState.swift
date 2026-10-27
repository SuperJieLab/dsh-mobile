/**
 * 设置页的依赖面：组网（录入 + 节点事实）与身份（有没有凭证、能不能解除）。
 *
 * 它只被设置页使用，但**不是**「一屏一个 state」意义上的那份 —— 组网与身份各有自己的
 * 状态对象（`MeshSetupState` / `RpcClient`），这一层只是把它们放在一起给一个视图读，
 * 与 `MeshSettingsState` 同一个理由。
 *
 * **引用 ≠ 拥有**：`meshSettings` 与 `client` 都是根造的、与进程同寿。解除配对会清掉
 * 沙盒里的设备凭证（`RpcClient.sever`），那是身份对象自己的事，不由这一层执行删除动作。
 *
 * 这里不放中文：组网那行的句子在 `MeshSettings/Display/MeshText.swift`。
 */
import Foundation

@MainActor
final class SettingsState {
    let meshSettings: MeshSettingsState
    private let client: RpcClient

    init(meshSettings: MeshSettingsState, client: RpcClient) {
        self.meshSettings = meshSettings
        self.client = client
    }

    /// 有没有身份。读穿到客户端 —— 它翻假时这一页会自动重算。
    var isPaired: Bool { client.isPaired }

    /// 组网那一行的副标题：阶段 + 路径（就绪时）。
    var meshSummary: String {
        let phase = meshSettings.store.phase
        guard case .ready = phase else { return meshPhaseText(phase) }
        return carrierPathText(meshSettings.store.meshPath).map { "\(meshPhaseText(phase)) · \($0)" }
            ?? meshPhaseText(phase)
    }

    /// 解除配对：清掉本地凭证与在手票。服务端那边由 Mac 侧撤销，这里只管本机。
    func unlink() {
        client.sever()
    }
}
