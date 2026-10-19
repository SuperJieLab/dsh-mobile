/**
 * 真实类型到连接域接缝的适配（R3 决定 2/3/4）：`GatewayClient` / `TailnetNode`
 * 各自认识自己的窄面，一行声明即注入 `ConnectionStore`。只进 App target，
 * 不进测试编译面 —— 测试用假件（ConnectionStoreTests.swift）。
 */
import Foundation

extension GatewayClient: GatewayActivating {}

extension TailnetNode: MeshNodeControlling {
    var nodeState: TailnetNodeState { state }

    /// 节点层的连接方式原样交给连接域 —— 两边用的是同一个类型（R19：取值只声明一次，
    /// 住被依赖的一方 `CarrierPath`），这里没有映射可做。
    var carrierPath: CarrierPath? { meshPath }

    func launchNode(config: MeshConfig) async {
        await launch(config: config)
    }

    func reviveNode() async {
        await revive()
    }
}
