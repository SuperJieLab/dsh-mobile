/**
 * 组网阶段 —— `TailnetNodeState` 与「传输是否建成」两个输入定一个取值，不自建迁移表。
 *
 * 与 `ConnectionPhase` 不同：这一层说隧道通不通。**身份不进这个枚举** —— 凭证可以存着而
 * 链路断开，混进来会让「连接中」与「未配对」互相遮蔽。
 */
enum MeshPhase: Equatable {
    /// 无 key：引导去设置页。
    case needsSetup
    /// 注册中，或已 running 但传输尚未切换（`gatewaySession` 建成前的窄窗口）。
    case connecting
    /// 组网已就绪。连接方式（直连 / 中继）单独走 `meshPath` —— 它随链路质量变，
    /// 与「能不能连」是两个变化原因。
    case ready
    /// 节点失败，原因可区分（badKey 引导重输 / unreachable 如实显示）。
    case failed(TailnetNodeFailure)

    /// 纯投影：两个输入定一个阶段。断言在 `tests/MeshStoreTests.swift`。
    static func resolve(nodeState: TailnetNodeState,
                        hasGatewaySession: Bool) -> MeshPhase {
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

    /// 恢复时该重走一次注册吗。
    ///
    /// 只有 `.failed(.unreachable)` 是。key 被拒不重试：同样的 key 再问一次答案不会变，
    /// 而 authkey 有使用次数限制 —— 那两档都是 `.failed`，最容易写反。
    var shouldRetryRegistration: Bool {
        if case .failed(.unreachable) = self { return true }
        return false
    }
}
