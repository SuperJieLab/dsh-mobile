/**
 * 组网状态的句子 —— 设置页的副标题读它。
 *
 * 住 `Display/`：`State/` 不放用户可见的中文，「未配置」是产品决定。
 */
import Foundation

/// 组网阶段的一句话。
func meshPhaseText(_ phase: MeshPhase) -> String {
    switch phase {
    case .needsSetup: "未配置"
    case .connecting: "连接中…"
    case .ready: "已入虚拟网"
    case .failed(.badKey): "密钥无效"
    case .failed(.unreachable): "组网服务不可达"
    }
}

/// 节点五态的一句话 —— 连接详情页读它。
///
/// 与 `meshPhaseText` 是两种事实（网关通不通 / 节点起没起来），所以 `.registering` 不写
/// 「连接中…」；两个函数仍住一处，免得这些词长出第二份。
func nodeStateText(_ state: TailnetNodeState) -> String {
    switch state {
    case .noKey: "未配置"
    case .registering: "注册中"
    case .running: "已入虚拟网"
    case .failed(.badKey): "密钥无效或过期"
    case .failed(.unreachable): "组网服务不可达"
    }
}

/// 组网设置页「提交被拒」的那句话：说清在等什么（接入结束，最长约 49 秒），
/// 而不是只说「不行」。措辞住这里，`State/` 只给原因。
extension MeshSetupState.BlockedReason {
    var text: String {
        switch self {
        case .nodeStarting: "正在接入虚拟网，接入结束后再试。"
        }
    }
}
