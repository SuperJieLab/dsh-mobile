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

/// 节点五态的一句话 —— 连接的详情页读它。
///
/// 与 `meshPhaseText` 是两种事实、两种措辞：那个说的是「这台机器跟网关通不通」（阶段），
/// 这个说的是「组网节点自己起没起来」。所以 `.registering` 写「注册中」而不是「连接中…」。
/// **但两个函数住在同一处**：两者都是组网域的文案，分开住会让「未配置」「已入虚拟网」
/// 这些词在仓库里长出第二份。
func nodeStateText(_ state: TailnetNodeState) -> String {
    switch state {
    case .noKey: "未配置"
    case .registering: "注册中"
    case .running: "已入虚拟网"
    case .failed(.badKey): "密钥无效或过期"
    case .failed(.unreachable): "组网服务不可达"
    }
}

/// 组网设置页「提交被拒」的那句话。
///
/// 说清**在等什么**（接入结束，最长约 49 秒），而不是只说「不行」—— 用户才知道该等
/// 还是该去查地址。措辞住这里，`State/` 只给原因。
extension MeshSetupState.BlockedReason {
    var text: String {
        switch self {
        case .nodeStarting: "正在接入虚拟网，接入结束后再试。"
        }
    }
}
