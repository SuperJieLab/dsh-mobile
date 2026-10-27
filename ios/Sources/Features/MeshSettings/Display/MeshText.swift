/**
 * 组网状态的句子 —— 设置页那一行的副标题读它。
 *
 * 住在 `Display/` 而不是 `State/`：`State/` 里不许出现用户可见的中文（那是产品决定，
 * 不是协议事实），而「未配置」这四个字正是产品决定。
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

/// 路径名：直连还是中继。没有路径时什么都不说（未就绪时那一行另有话说）。
func carrierPathText(_ path: CarrierPath?) -> String? {
    switch path {
    case .direct: "直连"
    case .relay: "中继"
    case nil: nil
    }
}
