/**
 * 组网域的唯一宿主：把「节点 × 身份 × 传输」三段收敛为一个对外阶段。
 *
 * 迁移判定仍在纯状态机 `TailnetNodeState`，这里不做第二台 —— `MeshPhase.resolve`
 * 只是它加「组网传输是否建成」这一个输入后的**投影**。启动编排、VerifiedRunning 激活、
 * 回前台探活住在这里。
 *
 * 与 `GatewayClient`：client 是 op 门面 + 身份状态机，由根部创建后传进来；本 store 只在
 * 节点验证 Running 时调一次 `activate` —— 组网域不吞身份域，业务调用面照旧直接消费 client。
 * 端点在激活前不存在。
 */
import Foundation
import Combine

// MARK: - 注入接缝
//
// store 只认这两个协议，不认具体类型 —— 真实类型的适配住在 `MeshStoreAdapters.swift`
// （App target；store 的测试经 `@testable import` + 假件注入，不牵真实
// TailscaleKit / GatewayClient，见 tests/MeshStoreTests.swift）。

/// 组网激活能力：`GatewayClient.activate` 的窄面。
///
/// 只放 store 真正读的成员 —— 投影不读身份，签名里也就没有它：连接阶段只由节点状态
/// 与「组网传输是否建成」这两个输入决定。
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
    /// 所以激活只能挂回调，不能靠观察状态变化）。
    var onVerifiedRunning: ((URLSession) -> Void)? { get set }
    /// 节点侧任何对外可见事实变化（状态迁移 / 路径刷新）的推送通道：视图已不观察
    /// 节点的 @Published，store 的投影靠它回灌 —— 没有它，轮询探到的失败与
    /// direct↔relay 切换会冻结在最近一次 store 调用的快照上。
    var onNodeChanged: (() -> Void)? { get set }
    func launchNode(config: MeshConfig) async
    func reviveNode() async
    /// 组网管理动作（设置页）：提交接入 key / failed 后重试。判定仍在节点层状态机。
    func submitKey(_ key: String, config: MeshConfig) async
    func retry(config: MeshConfig) async
}

@MainActor
final class MeshStore: ObservableObject {

    /// 对外连接阶段 —— 视图读连接态的唯一出处。
    @Published private(set) var phase: MeshPhase
    /// 节点层状态的细粒度透传：`phase` 把 registering 与 running-未组网都折进
    /// connecting，组网管理屏要区分这两态，故单独暴露（读取面仍唯一出处）。
    @Published private(set) var nodeState: TailnetNodeState
    /// 直连 / 中继；非 ready 期为 nil。徽章路径那一行的独立数据源 —— 它不折进
    /// `phase`，因为「连上了」与「走的是哪条路」是两个不同的变化原因。
    @Published private(set) var meshPath: CarrierPath?
    /// 读盘时发现组网配置损坏（存过，但解不出来）。节点不会启动 —— 详情见
    /// `reportDamagedConfiguration`。界面据此说「重新填写」，而不是「检查证书」。
    @Published private(set) var storedConfigDamaged = false

    private let client: GatewayActivating
    private let node: MeshNodeControlling
    /// 组网是否已激活（回调已 firing 且 activate 已调）。
    private var tailnetActivated = false
    /// 组网配置的当前值：start 存底，组网管理动作（submitKey / retry）刷新 ——
    /// VerifiedRunning 回调读它而不是读 start 时刻的快照，否则换了地址之后重入
    /// 仍然打到旧地址。
    private var config: MeshConfig?
    /// 启动编排的进程内幂等闸：列表页 `.task` 会随视图重入重放，二次 start 会经
    /// node.launch 重启 tsnet、杀掉活连接并清掉路径展示。
    private var started = false

    init(client: GatewayActivating, node: MeshNodeControlling) {
        self.client = client
        self.node = node
        self.nodeState = node.nodeState
        self.phase = MeshPhase.resolve(nodeState: node.nodeState,
                                             hasGatewaySession: false)
    }

    /// 启动编排：挂回调 + 拉起节点。激活只发生在 VerifiedRunning 回调里，没有兜底激活 ——
    /// 激活前 App 不持有任何网关地址。
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

    /// 回前台探活：探活判定在节点层，失败如实落 failed、不自动重试（重试入口在设置页）。
    /// 路径刷新以节点推送为准 —— revive 成功路径的刷新是异步的，这里只兜一次同步读。
    func sceneActive() async {
        await node.reviveNode()
        nodeChanged()
    }

    /// 配置读坏了：不进节点层，把「要重新填」这件事如实说出来。
    ///
    /// 不走 `start` 的理由：`start` 会把配置交给节点，而损坏的配置只能回落成空配置 ——
    /// 空配置过不了 `isComplete`，节点层于是报「不可达」，界面引导用户去查 VPS 与证书。
    /// 归因从第一步就错了，而用户按那个提示查不出任何东西。
    func reportDamagedConfiguration() {
        guard !started else { return }
        started = true
        storedConfigDamaged = true
        nodeState = .noKey
        phase = .needsSetup
    }

    // MARK: - 组网管理（设置页动作透传；判定在节点层，这里只接顺序）

    func submitMeshKey(_ key: String, config: MeshConfig) async {
        self.config = config
        // 用户重填过了 —— 上一次的「读坏」到此为止。再坏会是下一次读盘的事。
        storedConfigDamaged = false
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
        // 投影的输入由 `resolve` 的签名定死：节点状态 + 传输是否建成。身份不进来 ——
        // 离线也可能已配对，两件事互不决定。
        nodeState = node.nodeState
        phase = MeshPhase.resolve(nodeState: node.nodeState,
                                        hasGatewaySession: tailnetActivated)
    }
}
