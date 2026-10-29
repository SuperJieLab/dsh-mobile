/**
 * 组网域的唯一宿主：把「节点状态」收敛为「能不能发请求」，并持有隧道的唯一产物。
 *
 * 迁移判定仍在纯状态机 `TailnetNodeState`，这里不做第二台 —— `MeshPhase.resolve`
 * 只是它加「隧道是否建成」这一个输入后的**投影**。启动编排、VerifiedRunning 激活、
 * 回前台探活住在这里。
 *
 * **产物也住这里**：隧道通了之后「往哪打、走哪条传输」由 `route` 一次给全，不再有第二个
 * 对象存着它的一半。地址与传输同生共死 —— 没有「有地址但没有传输」这种态。
 *
 * 业务调用面照旧直接消费 `RpcClient`：组网域不吞身份域。
 */
import Foundation

// MARK: - 注入接缝
//
// store 只认一个协议，不认具体类型 —— 真实类型的适配住在 `MeshStoreAdapters.swift`
// （App target；store 的测试经 `@testable import` + 假件注入，不牵真实
// TailscaleKit，见 tests/MeshStoreTests.swift）。

/// 组网管理动作（提交接入 key / 失败后重试）有没有被接下。
///
/// **`busy` 不是失败，是「此刻不接」**：节点正在起的时候再起一条，会让两条注册互相
/// 清产物、让状态机的终局互相覆盖。入口如实说没接，怎么讲这件事归调用方。
enum MeshActionOutcome: Equatable {
    case accepted
    case busy
}

/// 组网节点能力：`TailnetNode` 的窄面。状态仍由 `TailnetNodeState` 状态机判定，
/// 本协议只暴露读取与既有入口，不做任何新判定。
@MainActor protocol MeshNodeControlling: AnyObject {
    var nodeState: TailnetNodeState { get }
    /// 当前到网关对端的路径；Running 期间由节点层轮询刷新，其余为 nil。
    var carrierPath: CarrierPath? { get }
    /// 节点正在起（`up()` 那段还没跑完）。**与 `nodeState` 不是一回事**：
    /// 状态目录健康时 `nodeState` 一上来就是 `.running`，而节点可能正卡在连控制面。
    /// 设置页据此在提交前就说清「此刻改不了」，不必等提交被拒才知道。
    var isStarting: Bool { get }
    /// 节点验证 Running、tailnet session 建成的那一刻（同值迁移不触发 onChange，
    /// 所以激活只能挂回调，不能靠观察状态变化）。
    var onVerifiedRunning: ((URLSession) -> Void)? { get set }
    /// 节点侧任何对外可见事实变化（状态迁移 / 路径刷新）的推送通道：视图不直接观察
    /// 节点，store 的投影靠它回灌 —— 没有它，轮询探到的失败与
    /// direct↔relay 切换会冻结在最近一次 store 调用的快照上。
    var onNodeChanged: (() -> Void)? { get set }
    func launchNode(config: MeshConfig) async
    func reviveNode() async
    /// 组网管理动作（设置页）：提交接入 key / failed 后重试。判定仍在节点层状态机。
    /// 节点正在起时返回 `.busy` —— 同一时刻只允许一条起节点的路。
    func submitKey(_ key: String, config: MeshConfig) async -> MeshActionOutcome
    func retry(config: MeshConfig) async -> MeshActionOutcome
}

@MainActor
@Observable
final class MeshStore {

    /// 对外连接阶段 —— 视图读连接态的唯一出处。**算出来的，不存**：它的两个输入
    /// （节点状态、隧道是否建成）各有唯一出处，再存一份就是第三个存放处。
    var phase: MeshPhase {
        MeshPhase.resolve(nodeState: nodeState, hasGatewaySession: route != nil)
    }
    /// 节点层状态的细粒度透传：`phase` 把 registering 与 running-未组网都折进
    /// connecting，组网管理屏要区分这两态，故单独暴露（读取面仍唯一出处）。
    private(set) var nodeState: TailnetNodeState
    /// 直连 / 中继；非 ready 期为 nil。徽章路径那一行的独立数据源 —— 它不折进
    /// `phase`，因为「连上了」与「走的是哪条路」是两个不同的变化原因。
    private(set) var meshPath: CarrierPath?
    /// 读盘时发现组网配置损坏（存过，但解不出来）。节点不会启动 —— 详情见
    /// `reportDamagedConfiguration`。界面据此说「重新填写」，而不是「检查证书」。
    private(set) var storedConfigDamaged = false

    /// 组网**刚刚**就绪的那一刻 —— 供编排层接（叫醒连接）。
    ///
    /// 与 `phase` 的分工：`phase` 回答「现在是什么」，视图读它画；这个回调回答
    /// 「它刚变成 ready」，动作层读它做。**两者不能互相替代** —— 观察 `phase` 只能
    /// 在渲染时顺便发生，而「组网好了该去连」必须发生 even 当没有任何视图在渲染。
    ///
    /// 只在「变成 `.ready` 且上一次不是」时调，不是每次回灌都调。
    var onPhaseReady: (() -> Void)?

    /// 上一次通知过的阶段。判「变成」用 —— `phase` 是算出来的，没有别的变化可挂钩。
    /// **不对外暴露**：读它会读到过期值，那正好是别人该用 `phase` 的场合。
    private var lastNotifiedPhase: MeshPhase?

    /// 隧道的产物：往哪打、走哪条传输。**地址与传输同生共死** —— 没有「有地址但没有
    /// 传输」这种态，也没有「有传输但地址作废」这种态。
    struct Route {
        let session: URLSession
        let baseURL: URL
    }

    /// 节点验证 Running 那一刻拿到的产物。唯一写入点是 `onVerifiedRunning`。
    private var verifiedRoute: Route?

    /// 此刻能不能发、往哪发 —— 没有第二条路径能拿到这个答案。
    ///
    /// **守卫在读数上**：`nodeState` 不是 `.running` 就一定 nil，哪怕 `verifiedRoute`
    /// 还留着上一次的值。于是「`route != nil` ⟺ `phase == .ready`」是算出来的，
    /// 不靠谁记得清 —— 没有「清」这个动作可忘。
    var route: Route? {
        guard case .running = nodeState else { return nil }
        return verifiedRoute
    }

    private let node: MeshNodeControlling
    /// 组网配置的当前值：start 存底，组网管理动作（submitKey / retry）刷新 ——
    /// VerifiedRunning 回调读它而不是读 start 时刻的快照，否则换了地址之后重入
    /// 仍然打到旧地址。
    private var config: MeshConfig?
    /// 启动编排的进程内幂等闸：列表页 `.task` 会随视图重入重放，二次 start 会经
    /// node.launch 重启 tsnet、杀掉活连接并清掉路径展示。
    private var started = false

    init(node: MeshNodeControlling) {
        self.node = node
        self.nodeState = node.nodeState
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
            self.verifiedRoute = Route(session: session, baseURL: baseURL)
            self.nodeChanged()
        }
        node.onNodeChanged = { [weak self] in self?.nodeChanged() }
        await node.launchNode(config: config)
        nodeChanged()
    }

    /// 回前台：探活；上一轮判定为不可达的，**顺手重试一次**。
    ///
    /// - 节点正在起：**什么都不做**。状态目录健康时状态一上来就是 `.running`，而节点
    ///   此刻还没验证过 —— 这时探活多半读不出来，会把一次正常接入打成
    ///   `failed(unreachable)`；而 `.failed` 之后成功进不来（迁移表里没有那一格）。
    /// - 已就绪 / 注册中：只探活（`reviveNode`）。节点活着时重开会杀掉旧 socket，
    ///   而那条连接可能正好好的。
    /// - 判定不可达：探活没有意义（本来就不通），直接重走一次注册。
    ///   「用户回来了」是重新尝试最可靠的信号 —— 比后台定时器省电，时机也更准
    ///   （后台重试的成功率低：iOS 会限制后台网络，而失败次数会白白消耗）。
    /// - key 被拒：**不重试**。同样的 key 再问一次答案不会变，而 authkey 有使用次数限制。
    func sceneActive() async {
        if !node.isStarting {
            if case .failed(.unreachable) = nodeState, let config {
                await node.retry(config: config)
            } else {
                await node.reviveNode()
            }
        }
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
    }

    // MARK: - 组网管理（设置页动作透传；判定在节点层，这里只接顺序）

    /// 节点正在起。透传给设置页做「提交前先问一句」—— 判定仍在节点层，这里只转述。
    var isStarting: Bool { node.isStarting }

    /// 提交接入 key 并接入。
    ///
    /// **预判在改 `config` 之前**：`config` 是 `onVerifiedRunning` 组装路径时读的那一格。
    /// 忙时若先把它换成新配置，正在起的那条旧配置一旦成功，就会拿旧 session 配上新地址 ——
    /// 「地址与传输同生共死」当场破掉。所以忙时整条动作都不做。
    func submitMeshKey(_ key: String, config: MeshConfig) async -> MeshActionOutcome {
        guard !node.isStarting else { return .busy }
        self.config = config
        // 用户重填过了 —— 上一次的「读坏」到此为止。再坏会是下一次读盘的事。
        storedConfigDamaged = false
        let outcome = await node.submitKey(key, config: config)
        nodeChanged()
        return outcome
    }

    func retryMesh(config: MeshConfig) async -> MeshActionOutcome {
        guard !node.isStarting else { return .busy }
        self.config = config
        let outcome = await node.retry(config: config)
        nodeChanged()
        return outcome
    }

    /// 节点侧事实变化的统一回灌口：重读节点状态 + 刷路径。
    ///
    /// 只读一个输入 —— 阶段与「能不能发」都由 `nodeState` 与 `route` 在读数上算出来，
    /// 这里不再算第二遍。
    ///
    /// 「刚就绪」的通知也挂在这里：它是节点侧事实的唯一回灌口（状态迁移与路径刷新都经过），
    /// 放这儿不会漏；而 `phase` 是算出来的，没有别的「变化」可挂。
    private func nodeChanged() {
        nodeState = node.nodeState
        meshPath = node.carrierPath

        let now = phase
        let was = lastNotifiedPhase
        lastNotifiedPhase = now
        // 只在**跨进** ready 那一次通知。保持 ready 不动时不重复 —— 否则每一次路径刷新
        // 都会让连接重连一次，而那条连接可能正好好的。
        if case .ready = now, !(was == .ready) {
            onPhaseReady?()
        }
    }
}
