/**
 * 节点状态机：iOS 侧唯一的新逻辑，纯函数、不持网络对象、不 import UI。
 * 迁移表唯一源 = 状态机状态图；断言 = tests/MeshNodeStateTests.swift。
 *
 * 纪律映射：
 * - Failed 的 badKey ≠ unreachable 必须可区分（界面文案据此分叉）；
 * - App 挂起不迁移（停摆由 tsnet 前台复活 + 重连接力吸收）；
 * - 状态目录损坏一律回 noKey（fail-closed，与凭证损坏同口径）。
 */
import Foundation

enum TailnetNodeFailure: Equatable {
    case badKey        // key 无效/过期：引导重输
    case unreachable   // 控制面不可达：如实显示，不自动重试风暴
}

enum TailnetNodeState: Equatable {
    case noKey
    case registering
    case running
    case failed(TailnetNodeFailure)

    /// 事件（输入只有节点回调与用户动作，状态机不发起任何 I/O）。
    enum Event: Equatable {
        /// App 启动：沙盒有无 key + 上次节点持久状态是否完好（tsnet 状态目录）。
        case launch(keyPresent: Bool, nodeStateHealthy: Bool)
        /// 设置页提交接入 key（含 failed 后重输）。
        case keySubmitted
        case registrationSucceeded
        case registrationFailed(TailnetNodeFailure)
        /// failed 修复后重试；key 是否还在由存储侧判好再告诉状态机。
        case retry(keyPresent: Bool)
        /// running 中节点失联（复活失败等）。
        case nodeUnreachable
        /// 进后台：状态机不迁移，仍是 running。**当前无发射源**（后台路径走
        /// revive() + scenePhase，不进状态机）——保留是把「进后台不迁移」这个
        /// 决定固化在表里，作为决策档案。
        case appBackgrounded
    }

    /// 迁移表。返回新状态；未列出的 (state, event) 组合原样返回（稳态不变迁移）。
    /// `launch` 自带全部输入、不读旧 state，调用时可省 `from`。
    static func handle(_ event: Event, from state: TailnetNodeState = .noKey) -> TailnetNodeState {
        switch (state, event) {
        // 启动（初始 state 无意义，launch 自带全部输入）
        case (_, .launch(let keyPresent, let nodeStateHealthy)):
            switch (keyPresent, nodeStateHealthy) {
            case (false, _):      return .noKey
            case (true, true):    return .running   // 重开不重注册
            case (true, false):   return .registering
            }
        // noKey / failed → 用户动作 → registering
        case (.noKey, .keySubmitted),
             (.failed, .keySubmitted):
            return .registering
        // 注册结果
        case (.registering, .registrationSucceeded):
            return .running
        case (_, .registrationFailed(let reason)):
            return .failed(reason)
        // failed → 修复重试
        case (.failed, .retry(let keyPresent)):
            return keyPresent ? .registering : .noKey
        // running 稳态
        case (.running, .nodeUnreachable):
            return .failed(.unreachable)
        case (.running, .appBackgrounded):
            return .running
        case (.running, .registrationSucceeded):
            return .running   // 前台复活幂等
        // 其余组合：状态不变
        default:
            return state
        }
    }
}
