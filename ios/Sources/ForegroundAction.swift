/**
 * 回前台该动哪一步 —— 纯函数，只由 `MeshPhase` 决定。
 *
 * 为什么判定单独成一个文件：这条判定依据两样东西 ——「上一次判定为不可达」（组网域的事实）
 * 与「App 回到前台」（平台事件）。它要落在同时认识两者的那一层，而 `AppServices` 是全仓
 * 唯一一个；把判定抽出来，是为了「该 revive 还是 retry」能被穷举断言，不必跑整个装配。
 *
 * 为什么 key 被拒不重试：同样的 key 再问一次答案不会变，而 authkey 有使用次数限制。
 */
import Foundation

enum ForegroundAction: Equatable {
    /// 只探活：节点可能还活着，而重开会把一条正好好的连接杀掉。
    case revive
    /// 按存下来的那份配置重走一次注册。
    case retryStored
}

extension ForegroundAction {

    static func of(phase: MeshPhase) -> ForegroundAction {
        if case .failed(.unreachable) = phase { return .retryStored }
        return .revive
    }
}
