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
import Combine

// MARK: - 注入接缝（R3 决定 2、3）
//
// store 只认这两个协议，不认具体类型 —— 真实类型的适配住在 `ConnectionAdapters.swift`
// （App target，进 Xcode；CLI 测试只编本文件 + TailnetNodeState + MeshConfig，
// 因此 TailscaleKit / GatewayClient 全链路都不进测试编译面）。

/// 承载激活能力：`GatewayClient.activate` 的窄面。
protocol GatewayActivating: AnyObject {
    /// 当前身份关系是否存在（投影输入；身份轴不并入连接阶段，决定 5）。
    var isPaired: Bool { get }
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
    /// 节点层状态的细粒度透传：`phase` 把 registering 与 running-未承载都折进
    /// connecting，组网管理屏要区分这两态，故单独暴露（读取面仍唯一出处）。
    @Published private(set) var nodeState: TailnetNodeState
    /// 直连 / 中继；非 ready 期为 nil。徽章的独立数据源，口径与重构前一致。
    @Published private(set) var meshPath: CarrierPath?

    private let client: GatewayActivating
    private let node: MeshNodeControlling
    /// tailnet 承载是否已激活（回调已 firing 且 activate 已调）。
    private var tailnetActivated = false

    init(client: GatewayActivating, node: MeshNodeControlling) {
        self.client = client
        self.node = node
        self.nodeState = node.nodeState
        self.phase = ConnectionPhase.resolve(nodeState: node.nodeState,
                                             isPaired: client.isPaired,
                                             hasGatewaySession: false)
    }

    /// 启动编排（决定 6，原 DshMobileApp.task 根部三段中的两段）：
    /// ① 兜底激活 —— 配对请求不能等组网 Running，先用普通 session 打配置地址；
    /// ② 激活内化 —— 回调在本方法里挂上，消费方是 store 而非视图层；
    /// ③ 拉起节点。判定逻辑全部在节点层状态机，这里只管调用顺序。
    func start(config: MeshConfig) async {
        if let baseURL = config.gatewayBaseURL {
            client.activate(session: .shared, baseURL: baseURL)
        }
        node.onVerifiedRunning = { [weak self] session in
            guard let self, let baseURL = config.gatewayBaseURL else { return }
            self.client.activate(session: session, baseURL: baseURL)
            self.tailnetActivated = true
            self.reproject()
        }
        await node.launchNode(config: config)
        reproject()
        meshPath = node.carrierPath
    }

    /// 回前台探活（原 DshMobileApp.onChange(scenePhase) 段）：探活判定在节点层，
    /// 失败如实落 failed、不自动重试（重试入口在设置页）。
    func sceneActive() async {
        await node.reviveNode()
        reproject()
        meshPath = node.carrierPath
    }

    // MARK: - 组网管理（设置页动作透传；判定在节点层，这里只接顺序）

    func submitMeshKey(_ key: String, config: MeshConfig) async {
        await node.submitKey(key, config: config)
        reproject()
        meshPath = node.carrierPath
    }

    func retryMesh(config: MeshConfig) async {
        await node.retry(config: config)
        reproject()
        meshPath = node.carrierPath
    }

    private func reproject() {
        // 身份轴从 client 读（节点不认识身份，决定 5）；isPaired 当前不被枚举消费，
        // 是「组合门面」的预留输入。
        nodeState = node.nodeState
        phase = ConnectionPhase.resolve(nodeState: node.nodeState,
                                        isPaired: client.isPaired,
                                        hasGatewaySession: tailnetActivated)
    }
}

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
