/**
 * 真实类型到连接域接缝的适配（R3 决定 2/3/4）：`GatewayClient` / `TailnetNode`
 * 各自认识自己的窄面，一行声明即注入 `ConnectionStore`。只进 App target，
 * 不进测试编译面 —— 测试用假件（ConnectionStoreTests.swift）。
 */
import Foundation

extension GatewayClient: GatewayActivating {}

extension TailnetNode: MeshNodeControlling {
    var nodeState: TailnetNodeState { state }

    /// 节点层的 `MeshPath` 适配到域内类型。徽章那一侧的对应关系写在它自己的文件里
    /// （呈现层为通信层的类型写适配）；两份枚举的合一是 R19 的范围。
    var carrierPath: CarrierPath? {
        meshPath.map { $0 == .direct ? .direct : .relay }
    }

    func launchNode(config: MeshConfig) async {
        await launch(config: config)
    }

    func reviveNode() async {
        await revive()
    }
}
