/**
 * 连接域的唯一宿主：把「组网 × 身份 × 传输」三段收敛为一个对外阶段（R3）。
 *
 * 分工：迁移判定仍在纯状态机 `TailnetNodeState`（run-mesh.sh 断言对象），这里不做
 * 第二台状态机 —— `ConnectionPhase.resolve` 只是它加身份/承载两个输入后的**投影**
 * （决定 1）；启动兜底激活、VerifiedRunning 激活内化、回前台探活的编排住这里（决定 2、6）。
 *
 * 与 `GatewayClient` 的关系（决定 3）：client 是 op 门面 + 身份状态机，由根部创建
 * 传给本 store，store 只调它的 `activate` —— 连接域不吞身份域，业务调用面照旧
 * 直接消费 client。
 */
import Foundation

/// 对外连接阶段（R3 决定 1）：`TailnetNodeState` 的投影，不自建迁移表。
/// 身份轴（`isPaired`）不进这个枚举 —— 离线也可已配对，两轴正交（决定 5）。
enum ConnectionPhase: Equatable {
    /// 无 key：引导去设置页。
    case needsSetup
    /// 注册中，或已 running 但承载尚未切换（`gatewaySession` 建成前的窄窗口）。
    case connecting
    /// tailnet 承载已就绪。连接方式（直连 / 中继）单独走 `meshPath`，不进枚举 ——
    /// 徽章的两个数据源口径与重构前一致（`ConnectionBadge.swift` 头注释）。
    case ready
    /// 节点失败，原因可区分（badKey 引导重输 / unreachable 如实显示）。
    case failed(TailnetNodeFailure)

    /// 纯投影：三个输入定一个阶段。全组合断言见 tests/ConnectionStoreTests.swift（N1）。
    static func resolve(nodeState: TailnetNodeState,
                        isPaired: Bool,
                        hasGatewaySession: Bool) -> ConnectionPhase {
        switch nodeState {
        case .noKey:
            return .needsSetup
        case .registering:
            return .connecting
        case .running:
            return hasGatewaySession ? .ready : .connecting
        case .failed(let reason):
            return .failed(reason)
        }
    }
}
