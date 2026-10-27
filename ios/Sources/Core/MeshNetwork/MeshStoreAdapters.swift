/**
 * 真实类型到组网域接缝的适配：`TailnetNode` 认识自己的窄面，一行声明即注入 `MeshStore`。
 * 只进 App target，不进测试编译面 —— 测试用假件（`MeshStoreTests.swift`）。
 *
 * 隧道的产物（传输 + 地址）没有适配：它由 `MeshStore.route` 直接产出，没有第二个对象
 * 需要在两者之间翻译。
 */
import Foundation

extension TailnetNode: MeshNodeControlling {
    var nodeState: TailnetNodeState { state }

    /// 节点层的连接方式原样交给连接域 —— 两边用的是同一个 `CarrierPath`，
    /// 所以这里没有映射可做，加第三个取值时也不会有地方静默归到某一支。
    var carrierPath: CarrierPath? { meshPath }

    func launchNode(config: MeshConfig) async {
        await launch(config: config)
    }

    func reviveNode() async {
        await revive()
    }
}
