/**
 * 真实类型到组网域接缝的适配：`RpcClient` / `TailnetNode`
 * 各自认识自己的窄面，一行声明即注入 `MeshStore`。只进 App target，
 * 不进测试编译面 —— 测试用假件（`MeshStoreTests.swift`）。
 */
import Foundation

extension RpcClient: GatewayActivating {}

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
