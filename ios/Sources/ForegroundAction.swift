/**
 * 回前台该动哪一步 —— 纯函数，只由 `MeshPhase` 决定。
 *
 * 判定抽出来是为了能被穷举断言：它依据「上一次判定为不可达」与「App 回到前台」，只有
 * `AppServices` 同时认识两者。key 被拒不重试：同样的 key 再问一次答案不会变。
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
