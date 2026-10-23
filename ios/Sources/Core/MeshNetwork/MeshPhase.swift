/**
 * 组网阶段 —— `TailnetNodeState` 与「传输是否建成」两个输入定一个取值，不自建迁移表。
 *
 * 与 `ConnectionPhase` 回答的不是同一件事：这一层是「隧道通不通」，那一层是「socket 连没连上」。
 * 两者都叫「连接」会让界面上分不清该修哪一边，故本层不占用那个词。
 *
 * **身份不进这个枚举。** 它回答「此刻能不能发请求」，身份回答「谁配看」——两者正交：
 * 凭证可以存在而链路断开（离线也可已配对），链路可以通而凭证已失效。混进来会让
 * 「连接中」与「未配对」互相遮蔽。所以签名里没有身份参数。
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
}
