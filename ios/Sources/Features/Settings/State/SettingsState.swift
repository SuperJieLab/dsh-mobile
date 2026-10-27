/**
 * 设置页的依赖面：组网那一行的说法与身份（有没有凭证、能不能解除）。
 *
 * 它成立的依据是两条**组合**，不是「把两个对象装在一起」：`meshSummary` 把阶段与路径
 * 拼成一句副标题，`unlink` 把「用户点了解除」落到具体的清凭证动作上。零组合的容器是
 * 转发层（组网录入那一页就因此没有容器 —— 它的两个依赖直接进签名）。
 *
 * `isPaired` 是唯一一条纯读穿，但它不是转发：`client` 是 private，这一条是它的**唯一出口**
 * —— 视图拿到 `RpcClient` 就等于知道怎么发请求，那是禁的，所以读穿在这里是边界而非多余。
 *
 * **引用 ≠ 拥有**：`setup` / `store` / `client` 都是根造的、与进程同寿。解除配对会清掉
 * 沙盒里的设备凭证（`RpcClient.sever`），那是身份对象自己的事，不由这一层执行删除动作。
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
    private let client: RpcClient

    init(setup: MeshSetupState, store: MeshStore, client: RpcClient) {
        self.setup = setup
        self.store = store
        self.client = client
    }

    /// 有没有身份。读穿到客户端 —— 它翻假时这一页会自动重算。
    var isPaired: Bool { client.isPaired }

    /// 组网那一行的副标题：阶段 + 路径（就绪时）。
    var meshSummary: String {
        let phase = store.phase
        guard case .ready = phase else { return meshPhaseText(phase) }
        return carrierPathText(store.meshPath).map { "\(meshPhaseText(phase)) · \($0)" }
            ?? meshPhaseText(phase)
    }

    /// 解除配对：清掉本地凭证与在手票。服务端那边由 Mac 侧撤销，这里只管本机。
    func unlink() {
        client.sever()
    }
}
