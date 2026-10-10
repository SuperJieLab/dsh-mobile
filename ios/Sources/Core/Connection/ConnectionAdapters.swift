/**
 * 真实类型到连接域接缝的适配（R3 决定 2/3/4）：`GatewayClient` / `TailnetNode`
 * 各自认识自己的窄面，一行声明即注入 `ConnectionStore`。只进 App target，
 * 不进任何 run-*.sh 编译面 —— CLI 测试用假件（ConnectionStoreTests.swift）。
 */
import Foundation

extension GatewayClient: GatewayActivating {}

extension TailnetNode: MeshNodeControlling {
    var nodeState: TailnetNodeState { state }

    /// 节点层的 `MeshPath` 适配到域内类型（语义同 `ConnectionBadge.MeshPath` 的既有适配）。
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

/// 徽章从域内类型取连接方式（原 `TailnetNode.MeshPath` 适配位的替换）。
extension ConnectionBadge.MeshPath {
    init(_ path: CarrierPath) {
        self = path == .direct ? .direct : .relay
    }
}
