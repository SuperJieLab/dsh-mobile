/**
 * 连接域的唯一宿主：把「组网 × 身份 × 传输」三段收敛为一个对外阶段（R3）。
 *
 * 分工：迁移判定仍在纯状态机 `TailnetNodeState`（断言在 tests/MeshNodeStateTests.swift），这里不做
 * 第二台状态机 —— `ConnectionPhase.resolve` 只是它加「组网传输是否建成」这一个输入后的
 * **投影**（决定 1）；身份（`isPaired`）不进这个投影，两轴正交（决定 5）。
 * 启动兜底激活、VerifiedRunning 激活内化、回前台探活的编排住这里（决定 2、6）。
 *
 * 与 `GatewayClient` 的关系（决定 3）：client 是 op 门面 + 身份状态机，由根部创建
 * 传给本 store，store 只在节点验证 Running 时调一次 `activate` —— 连接域不吞身份域，
 * 业务调用面照旧直接消费 client。端点在激活前不存在（R5 契约）。
 */
import Foundation
import Combine

// MARK: - 注入接缝（R3 决定 2、3）
//
// store 只认这两个协议，不认具体类型 —— 真实类型的适配住在 `ConnectionAdapters.swift`
// （App target；store 的测试经 `@testable import` + 假件注入，不牵真实
// TailscaleKit / GatewayClient，见 tests/ConnectionStoreTests.swift）。

/// 组网激活能力：`GatewayClient.activate` 的窄面。
///
/// 只有 store 真正读的成员 —— 身份（`isPaired`）不在这个窄面上：连接阶段的投影不读它
/// （两轴正交，决定 5），签名里也就没有它。
@MainActor protocol GatewayActivating: AnyObject {
    func activate(session: URLSession, baseURL: URL)
}

/// 组网节点能力：`TailnetNode` 的窄面。状态仍由 `TailnetNodeState` 状态机判定，
/// 本协议只暴露读取与既有入口，不做任何新判定。
@MainActor protocol MeshNodeControlling: AnyObject {
    var nodeState: TailnetNodeState { get }
    /// 当前到网关对端的路径；Running 期间由节点层轮询刷新，其余为 nil。
    var carrierPath: CarrierPath? { get }
    /// 节点验证 Running、tailnet session 建成的那一刻（同值迁移不触发 onChange，
    /// 激活只能挂回调 —— 机制沿用 M8 T8 排障结论，消费方从视图根部改为本 store）。
    var onVerifiedRunning: ((URLSession) -> Void)? { get set }
    /// 节点侧任何对外可见事实变化（状态迁移 / 路径刷新）的推送通道：视图已不观察
    /// 节点的 @Published，store 的投影靠它回灌 —— 没有它，轮询探到的失败与
    /// direct↔relay 切换会冻结在最近一次 store 调用的快照上（R3 收口审查 C1）。
    var onNodeChanged: (() -> Void)? { get set }
    func launchNode(config: MeshConfig) async
    func reviveNode() async
    /// 组网管理动作（设置页）：提交接入 key / failed 后重试。判定仍在节点层状态机。
    func submitKey(_ key: String, config: MeshConfig) async
    func retry(config: MeshConfig) async
}

/// 到网关对端的连接方式（域内类型；`TailnetNode.MeshPath` 与
/// `ConnectionBadge.MeshPath` 各自适配到它）。
enum CarrierPath: Equatable {
    case direct
    case relay
}

@MainActor
final class ConnectionStore: ObservableObject {

    /// 对外连接阶段 —— 视图读连接态的唯一出处（决定 4）。
    @Published private(set) var phase: ConnectionPhase
    /// 节点层状态的细粒度透传：`phase` 把 registering 与 running-未组网都折进
    /// connecting，组网管理屏要区分这两态，故单独暴露（读取面仍唯一出处）。
    @Published private(set) var nodeState: TailnetNodeState
    /// 直连 / 中继；非 ready 期为 nil。徽章的独立数据源，口径与重构前一致。
    @Published private(set) var meshPath: CarrierPath?

    private let client: GatewayActivating
    private let node: MeshNodeControlling
    /// 组网是否已激活（回调已 firing 且 activate 已调）。
    private var tailnetActivated = false
    /// 组网配置的当前值：start 存底，组网管理动作（submitKey / retry）刷新 ——
    /// VerifiedRunning 回调读它而不是读 start 时刻的快照（收口审查 M1：
    /// 旧版每次 firing 重读 MeshConfig.load()，换地址后重入要打到新地址）。
    private var config: MeshConfig?
    /// 启动编排的进程内幂等闸（真机 2026-10-10：列表页 `.task` 随视图重入重放，
    /// 二次 start 会经 node.launch 重启 tsnet、杀掉活连接并清掉路径展示）。
    private var started = false

    init(client: GatewayActivating, node: MeshNodeControlling) {
        self.client = client
        self.node = node
        self.nodeState = node.nodeState
        self.phase = ConnectionPhase.resolve(nodeState: node.nodeState,
                                             hasGatewaySession: false)
    }

    /// 启动编排（决定 6，R5 起无兜底激活）：挂回调 + 拉起节点。激活只发生在
    /// VerifiedRunning 回调里 —— 激活前 App 不持有任何网关地址（R5 契约）。
    /// 判定逻辑全部在节点层状态机，这里只管调用顺序。
    func start(config: MeshConfig) async {
        // 幂等：启动编排一次进程只该走一遍。重入（视图重放 .task）只刷新投影，
        // 不重拉节点。回前台的恢复走 sceneActive，与此无关。
        guard !started else {
            nodeChanged()
            return
        }
        started = true
        self.config = config
        node.onVerifiedRunning = { [weak self] session in
            guard let self, let baseURL = self.config?.gatewayBaseURL else { return }
            self.client.activate(session: session, baseURL: baseURL)
            self.tailnetActivated = true
            self.reproject()
        }
        node.onNodeChanged = { [weak self] in self?.nodeChanged() }
        await node.launchNode(config: config)
        reproject()
        meshPath = node.carrierPath
    }

    /// 回前台探活（原 DshMobileApp.onChange(scenePhase) 段）：探活判定在节点层，
    /// 失败如实落 failed、不自动重试（重试入口在设置页）。路径刷新以节点推送为准
    /// （revive 成功路径的刷新是异步的，这里只兜一次同步读，收口审查 C2）。
    func sceneActive() async {
        await node.reviveNode()
        nodeChanged()
    }

    // MARK: - 组网管理（设置页动作透传；判定在节点层，这里只接顺序）

    func submitMeshKey(_ key: String, config: MeshConfig) async {
        self.config = config
        await node.submitKey(key, config: config)
        nodeChanged()
    }

    func retryMesh(config: MeshConfig) async {
        self.config = config
        await node.retry(config: config)
        nodeChanged()
    }

    /// 节点侧事实变化的统一回灌口：重投影 + 刷路径。
    private func nodeChanged() {
        reproject()
        meshPath = node.carrierPath
    }

    private func reproject() {
        // 身份轴不进连接阶段（决定 5：离线也可已配对，两轴正交）—— 这件事现在由
        // `resolve` 的签名表达，不再靠一条注释加一层测试循环去说明。
        nodeState = node.nodeState
        phase = ConnectionPhase.resolve(nodeState: node.nodeState,
                                        hasGatewaySession: tailnetActivated)
    }
}

/// 对外连接阶段（R3 决定 1）：`TailnetNodeState` 的投影，不自建迁移表。
/// 身份轴（`isPaired`）不进这个枚举 —— 离线也可已配对，两轴正交（决定 5）。
enum ConnectionPhase: Equatable {
    /// 无 key：引导去设置页。
    case needsSetup
    /// 注册中，或已 running 但传输尚未切换（`gatewaySession` 建成前的窄窗口）。
    case connecting
    /// 组网已就绪。连接方式（直连 / 中继）单独走 `meshPath`，不进枚举 ——
    /// 徽章的两个数据源口径与重构前一致（`ConnectionBadge.swift` 头注释）。
    case ready
    /// 节点失败，原因可区分（badKey 引导重输 / unreachable 如实显示）。
    case failed(TailnetNodeFailure)

    /// 纯投影：两个输入定一个阶段（身份不进这个投影，决定 5）。断言见
    /// `tests/ConnectionStoreTests.swift`（N1）。
    static func resolve(nodeState: TailnetNodeState,
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
