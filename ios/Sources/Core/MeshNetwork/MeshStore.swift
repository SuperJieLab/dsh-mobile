/**
 * 组网域的唯一宿主：把「节点状态」收敛为「能不能发请求」，并持有隧道的唯一产物。
 *
 * 迁移判定在纯状态机，`MeshPhase.resolve` 只是加「隧道是否建成」之后的投影。
 * 动作（探活 / 重试）住这里，「什么时候动」在编排。
 */
import Foundation

// MARK: - 注入接缝（真实类型的适配住 `MeshStoreAdapters.swift`）

/// 组网节点能力：`TailnetNode` 的窄面。状态仍由 `TailnetNodeState` 状态机判定，
/// 本协议只暴露读取与既有入口，不做任何新判定。
@MainActor protocol MeshNodeControlling: AnyObject {
    var nodeState: TailnetNodeState { get }
    /// 当前到网关对端的路径；Running 期间由节点层轮询刷新，其余为 nil。
    var carrierPath: CarrierPath? { get }
    /// 节点验证 Running、tailnet session 建成的那一刻（同值迁移不触发 onChange，
    /// 所以激活只能挂回调，不能靠观察状态变化）。
    var onVerifiedRunning: ((URLSession) -> Void)? { get set }
    /// 节点侧事实变化的推送通道 —— 没有它，探到的失败与 direct↔relay 切换会冻结在快照上。
    var onNodeChanged: (() -> Void)? { get set }
    func launchNode(config: MeshConfig) async
    func reviveNode() async
    /// 组网管理动作（提交接入 key / failed 后重试）。判定仍在节点层状态机。
    /// 没有「忙时拒绝」这一支：用户给的是新配置，在跑那次的结论已经不相关了 —— 节点层会在
    /// 提交的那一刻让旧一代作废，所以这里连回执都不需要。
    func submitKey(_ key: String, config: MeshConfig) async
    func retry(config: MeshConfig) async
}

@MainActor
@Observable
final class MeshStore {

    /// 对外连接阶段 —— 视图读连接态的唯一出处。**算出来的，不存**。
    var phase: MeshPhase {
        MeshPhase.resolve(nodeState: nodeState, hasGatewaySession: route != nil)
    }
    /// 节点层状态透传：组网管理屏要区分 registering 与 running-未组网。
    private(set) var nodeState: TailnetNodeState
    /// 直连 / 中继；非 ready 期为 nil。不折进 `phase`（两个变化原因）。
    private(set) var meshPath: CarrierPath?
    /// 读盘时发现组网配置损坏（存过但解不出来）；节点不会启动。
    private(set) var storedConfigDamaged = false

    /// 组网阶段**变了** —— 带旧值与新值两端。
    ///
    /// 只报变化，不判断「这次变化意味着什么」：「跨进 ready 该叫醒谁」是编排层的事
    /// （只有它同时认识组网与连接）。视图读 `phase` 画，不订阅这个。
    /// `old` 可选：`nil` 表示还没有过值 —— 那是「尚未确立」，不是从某个阶段变来的。
    var onPhaseChanged: ((_ old: MeshPhase?, _ new: MeshPhase) -> Void)?

    /// 隧道**产物被换掉了** —— 新一代接入建成，`route` 已换成另一个会话。
    ///
    /// 与 `onPhaseChanged` 分开，因为两者要的动作相反：阶段跨进 ready 是「叫醒一条在等地址的
    /// 连接」，产物换代是「拆掉一条握着旧产物的连接」。首次就绪只报前者 —— 那时还没有连接可拆。
    ///
    /// 不带参数：`route` 是「此刻能不能发、往哪发」的唯一真相，参数化会多一个「参数与属性
    /// 不一致」的窗口；接收方读 `route` 拿到的永远是当下那一刻。
    var onRouteReplaced: (() -> Void)?

    /// 上一次通知过的阶段 —— `phase` 是算出来的，没有别的变化可挂钩。
    private var lastNotifiedPhase: MeshPhase?

    /// 上一次报过的产物会话。换代判据就是「这次可见的会话不是上一次那个」——
    /// 用会话身份而不是「收到过一次成功回调」：重入会重放同一个会话，那不是换代。
    private var lastNotifiedSession: URLSession?

    /// 隧道的产物：往哪打、走哪条传输。**地址与传输同生共死** —— 没有「有地址但没有
    /// 传输」这种态，也没有「有传输但地址作废」这种态。
    struct Route {
        let session: URLSession
        let baseURL: URL
    }

    /// 节点验证 Running 那一刻拿到的产物。唯一写入点是 `onVerifiedRunning`。
    private var verifiedRoute: Route?

    /// 此刻能不能发、往哪发。**守卫在读数上**：`nodeState` 不是 `.running` 就一定 nil，
    /// 于是「`route != nil` ⟺ `phase == .ready`」是算出来的，没有「清」这个动作可忘。
    var route: Route? {
        guard case .running = nodeState else { return nil }
        return verifiedRoute
    }

    private let node: MeshNodeControlling
    /// 组网配置的当前值：start 存底，submitKey / retry 刷新。
    /// VerifiedRunning 读它而不是 start 时的快照，否则换地址后重入仍打旧地址。
    private var config: MeshConfig?
    /// 进程内幂等闸：二次 start 会重启 tsnet、杀掉活连接并清掉路径。
    private var started = false

    init(node: MeshNodeControlling) {
        self.node = node
        self.nodeState = node.nodeState
    }

    /// 启动编排：挂回调 + 拉起节点；激活只发生在 VerifiedRunning 回调里。
    /// 判定全在节点层状态机，这里只管调用顺序。
    func start(config: MeshConfig) async {
        // 幂等：启动编排一次进程只该走一遍。重入（视图重放 .task）只刷新投影，
        // 不重拉节点。回前台的恢复走 `AppServices.sceneActive`，与此无关。
        guard !started else {
            nodeChanged()
            return
        }
        started = true
        self.config = config
        node.onVerifiedRunning = { [weak self] session in
            guard let self, let baseURL = self.config?.gatewayBaseURL else { return }
            // 只管把这一对装起来（地址与传输同生共死）；报不报换代由回灌口判 ——
            // 判据是「此刻可见的会话换没换」，那需要三个投影都在手里。
            //
            // 地址取自**此刻**的 `config`，不是「产生这个 session 的那次配置」。两者相等靠的是
            // 一条不在签名里的前提：改配置必经 `submitKey` / `retry` → 节点层换代 → 新 session，
            // 所以旧 session 不可能配上新地址（旧一代的回调在换代时已作废）。
            self.verifiedRoute = Route(session: session, baseURL: baseURL)
            self.nodeChanged()
        }
        node.onNodeChanged = { [weak self] in self?.nodeChanged() }
        await node.launchNode(config: config)
        nodeChanged()
    }

    /// 探活一次：节点还活着就重读路径，读不出就落 `failed(unreachable)`。
    /// 只回答「能不能做」；「该不该做」在编排，接入途中不探活由节点自己守。
    func revive() async {
        await node.reviveNode()
        nodeChanged()
    }

    /// 按**存下来的那份**配置重走一次注册。
    /// 不带参数是有意的：让编排传参就有两种可能，而「旧 session 配新地址」正是那样来的。
    /// 不回答「接没接」：内部动作，没有第二方等回执。
    func retryStored() async {
        guard let config else { return }
        await retryMesh(config: config)
    }

    /// 配置读坏了：不进节点层，把「要重新填」如实说出来。
    /// 交给 `start` 会回落成空配置 → 报「不可达」→ 用户去查 VPS 与证书，归因从第一步就错。
    func reportDamagedConfiguration() {
        guard !started else { return }
        started = true
        storedConfigDamaged = true
        nodeState = .noKey
    }

    // MARK: - 组网管理（设置页动作透传；判定在节点层，这里只接顺序）

    /// 提交接入 key 并接入。
    /// **不预判「节点正在起」**：用户改配置正是唯一能让在跑那次作废的动作，挡在门外等于
    /// 让他等旧那轮跑完。旧一代的结论由节点层代际判出去，不需要在这里互斥。
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

    /// 节点侧事实变化的统一回灌口（状态迁移与路径刷新都经过）。
    /// 三个投影都在这儿重算，两个对外信号也在这儿发。
    ///
    /// **先产物、后阶段**：换代时两者在同一次回灌里都变，反序则连接会先用旧会话被叫醒一次，
    /// 紧接着又被拆掉重建 —— 一次白连。顺序由这两个 `if` 的先后决定，不是调用方约定。
    private func nodeChanged() {
        nodeState = node.nodeState
        meshPath = node.carrierPath

        // 换代：此刻 `route` 已经是新的一对（两个投影刚刷新过），报出去接收方读到的就是它。
        if let session = route?.session, lastNotifiedSession !== session {
            let isReplacement = lastNotifiedSession != nil
            lastNotifiedSession = session
            // 首次就绪不是换代：那之前没有任何连接握着旧产物，没什么可拆的。
            if isReplacement { onRouteReplaced?() }
        }

        let now = phase
        let was = lastNotifiedPhase
        lastNotifiedPhase = now
        // 变了就报，两端都给出去。**同值不报**：每次路径刷新（direct↔relay）都会回灌一次，
        // 报了就成「每次刷新都叫醒一次」，而那条连接可能正好好的。
        if was != now {
            onPhaseChanged?(was, now)
        }
    }
}
