/**
 * 节点状态机：纯函数、不持网络对象、不 import UI。迁移表的唯一源就是这里的状态图。
 *
 * 三条纪律：Failed 的四种原因必须可区分（文案据此分叉，补救也各不同）；App 挂起不迁移
 * （停摆由 tsnet 前台复活 + 重连吸收）；没有节点身份一律回 noIdentity（fail-closed）。
 *
 * **票（auth key）不在这张表里**：它从不落盘，只在用户提交那一次参与，注册成功即失去用途。
 * 所以「有没有票」不是状态，也不是事件输入。
 */
import Foundation

/// 节点起不来的原因。四格对应四种补救：换一把票 / 造一把票 / 等人 / 等网络。
enum TailnetNodeFailure: Equatable {
    /// 刚贴上去的票被控制面拒了 —— 票本身有问题。
    case badKey
    /// 本机没有可用的节点身份 —— 要去后台造一把票再贴。
    case needsAuthKey
    /// 已经登记，设备在等管理员批准 —— 只能等人。
    case pendingApproval
    /// 控制面不可达 —— 等网络，可重试。
    case unreachable
}

enum TailnetNodeState: Equatable {
    /// 没有节点身份（从未接入，或身份已被作废）。**不是**「没有票」。
    case noIdentity
    case registering
    case running
    case failed(TailnetNodeFailure)

    /// 事件（输入只有节点回调与用户动作，状态机不发起任何 I/O）。
    enum Event: Equatable {
        /// App 启动时的两件事实：`identityPresent` = 节点状态目录里有没有档案；
        /// `controlPlaneMatches` = 那份档案是不是属于这一家控制面。
        case launch(identityPresent: Bool, controlPlaneMatches: Bool)
        /// 设置页提交接入票（含 failed 后重输）。
        case keySubmitted
        case registrationSucceeded
        case registrationFailed(TailnetNodeFailure)
        /// failed 修复后重试。能不能试由两件事之一决定：有身份，或手里还留着这一进程的票。
        case retry(identityPresent: Bool, ticketPresent: Bool)
        /// running 中节点失联（复活失败等）。
        case nodeUnreachable
        /// 被新一代取代：这一代的一切结论作废。由节点层在「提交新配置、起新节点之前」发出。
        case superseded
        /// 进后台：状态机不迁移，仍是 running。**当前无发射源**（后台路径走
        /// revive() + scenePhase，不进状态机）——保留是把「进后台不迁移」这个
        /// 决定固化在表里，作为决策档案。
        case appBackgrounded
    }

    /// 迁移表。返回新状态；未列出的 (state, event) 组合原样返回（稳态不变迁移）。
    /// `launch` 自带全部输入、不读旧 state，调用时可省 `from`。
    static func handle(_ event: Event,
                       from state: TailnetNodeState = .noIdentity) -> TailnetNodeState {
        switch (state, event) {
        // 启动（初始 state 无意义，launch 自带全部输入）
        case (_, .launch(let identity, let matches)):
            // 身份在、且属于这一家：先去起。起得来起不来由上游的 BackendState 说话，
            // 「目录看起来健康」不再等于「已登录」。
            return identity && matches ? .running : .noIdentity
        // noIdentity / failed → 用户动作 → registering
        case (.noIdentity, .keySubmitted),
             (.failed, .keySubmitted):
            return .registering
        // 注册结果
        case (.registering, .registrationSucceeded):
            return .running
        case (_, .registrationFailed(let reason)):
            return .failed(reason)
        // failed → 修复重试：有身份或有票才有的试，两者都没有就只能说清「要重新接入」。
        case (.failed, .retry(let identity, let ticket)):
            return identity || ticket ? .registering : .noIdentity
        // 被新一代取代：旧一代停在 running 或 failed 时，都交回「接入中」——
        // running 必须离开（`MeshStore.route` 的守卫读它，不离开就还返回已关闭节点的 session）。
        // 另两格不单列：`.registering` 遇它仍是 registering、`.noIdentity` 仍是 noIdentity，
        // 两者与「未列出的组合返回原状态」逐字相同。
        case (.running, .superseded),
             (.failed, .superseded):
            return .registering
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
