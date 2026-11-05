/**
 * 组网阶段投影的断言。投影与编排见同目录的 `MeshStore.swift` 与 `MeshPhase.swift`；
 * 对外阶段只由「节点状态 + 传输是否建成」两个输入决定。判定逻辑本身在 `TailnetNodeState`
 * （断言在 `tests/MeshNodeStateTests.swift`），这里只断言「投影无漏组合、编排时点不丢」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class MeshStoreTests: XCTestCase {

    /// 阶段变化通知：带两端，同值不发。
    ///
    /// 「跨进 ready 才叫醒连接」这条判断已搬到接收方（编排层）—— 于是这条判据要证明的是
    /// 接收方需要的两样东西都在：**新值**与**旧值**；以及保持同值时不被重复打扰。
    ///
    /// 两件事分别会坏：每次回灌都发 ⇒ 每次路径刷新（direct↔relay 切换）都被接收方当成一次跨越，
    /// 于是重连一条正好好的连接；从不发 ⇒ 编排层收不到「组网好了」，连接永远停在等组网。
    func testPhaseChangedNotificationCarriesBothEnds() async {
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        var transitions: [(MeshPhase?, MeshPhase)] = []
        store.onPhaseChanged = { old, new in transitions.append((old, new)) }

        await store.start(config: config)

        // 隧道产物就位（`verifiedRoute` 的唯一写入点）→ 同时回灌一次。
        node.nodeState = .running
        node.onVerifiedRunning?(URLSession.shared)
        XCTAssertTrue(store.phase == .ready, "先确认真的就绪了，否则下面测的是别的分支")
        XCTAssertEqual(transitions.last?.1, .ready, "跨进 ready 要有一次通知")
        XCTAssertNotEqual(transitions.last?.0, .ready, "旧值不能也是 ready —— 否则接收方判不出「跨进」")

        let crossings = transitions.filter { $0.1 == .ready && $0.0 != .ready }.count
        XCTAssertEqual(crossings, 1, "第一条跨越")

        // 又一次回灌，阶段没变：不该发。
        let before = transitions.count
        node.onNodeChanged?()
        XCTAssertEqual(transitions.count, before, "阶段没变就不该发 —— 发了接收方就会重连一条好连接")

        // 掉下去再回来：两次都要发，接收方能自己算出第二次跨越。
        node.nodeState = .failed(.unreachable)
        node.onNodeChanged?()
        XCTAssertEqual(transitions.last?.1, .failed(.unreachable), "掉下去本身也是一次变化")
        node.nodeState = .running
        node.onNodeChanged?()
        XCTAssertEqual(transitions.last?.1, .ready)
        XCTAssertEqual(transitions.filter { $0.1 == .ready && $0.0 != .ready }.count, 2,
                       "再回到 ready 是第二次跨越")
    }

    func testOrchestration() async {
        // —— 投影的全组合（2 节点态 × 2 组网；`failed` 两半各一次）——
        // 身份轴不并入组网阶段 —— 这件事现在由 `resolve` 的签名表达：签名里没有
        // 身份输入，就不存在「配对与否」这一维组合。
        for session in [true, false] {
            let noKey = MeshPhase.resolve(
                nodeState: .noKey, hasGatewaySession: session)
            XCTAssertTrue(noKey == .needsSetup, "N1a noKey（session=\(session)）")

            let registering = MeshPhase.resolve(
                nodeState: .registering, hasGatewaySession: session)
            XCTAssertTrue(registering == .connecting, "N1b registering（session=\(session)）")

            let badKey = MeshPhase.resolve(
                nodeState: .failed(.badKey), hasGatewaySession: session)
            XCTAssertTrue(badKey == .failed(.badKey), "N1e failed(badKey)（session=\(session)）")

            let unreachable = MeshPhase.resolve(
                nodeState: .failed(.unreachable), hasGatewaySession: session)
            XCTAssertTrue(unreachable == .failed(.unreachable),
                          "N1f failed(unreachable)（session=\(session)）")
        }
        // running 的两半：session 未建成的窄窗口 = connecting；建成 = ready
        let switching = MeshPhase.resolve(nodeState: .running, hasGatewaySession: false)
        XCTAssertTrue(switching == .connecting, "N1c running 但传输未切换 → connecting")
        let switched = MeshPhase.resolve(nodeState: .running, hasGatewaySession: true)
        XCTAssertTrue(switched == .ready, "N1d running 且传输已切换 → ready")

        // —— K4：启动零激活 + VerifiedRunning 唯一激活点——
        // 激活前 App 不持有隧道产物；产物从无到有只发生在节点验证 Running 那一刻。
        let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        await store.start(config: config)
        XCTAssertNil(store.route,
                     "K4a start 不激活：未激活 = 没有产物，不兜底")

        // 唯一激活点：节点验证 Running → 产物恰出现一次（隧道 session + 配置地址）。
        let tunnel = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(tunnel)
        XCTAssertTrue(store.route?.session === tunnel
                      && store.route?.baseURL == config.gatewayBaseURL!,
                      "K4b VerifiedRunning 唯一激活点：产物一次建成（不穿视图层）")
        XCTAssertTrue(store.phase == .ready, "K4c 激活后阶段投影为 ready")

        // —— N2d/N2e：start 进程内幂等（列表页 .task 重入触发
        // 第二次 start → 节点重启 → 活连接被杀 + 徽章掉直连标签）——
        await store.start(config: config)
        XCTAssertTrue(store.route?.session === tunnel,
                      "N2d start 幂等：重复 start 不重建产物（也不清空已建成的）")
        XCTAssertTrue(node.launchCount == 1,
                      "N2e start 幂等：重复 start 不再拉起节点（tsnet 重启会杀活连接）")

        // —— 回前台恢复：唯一入口是 ensureReachable，探活与换代都是它的内部步骤 ——
        store.reachability = { _, _ in true }
        node.reviveShouldFail = true
        _ = await store.ensureReachable()
        XCTAssertTrue(store.phase == .failed(.unreachable),
                      "N3a 探活通过但节点读不出 → 如实落 failed(unreachable)")
        // **产物跟着判据失效**：阶段不再是 ready 时，路就不通了 —— 这不是靠谁去清，
        // 是 `route` 在读数上守卫。删掉那道守卫，两条都会红。
        XCTAssertNil(store.route,
                     "N3a2 隧道不可用时 route 必须为 nil —— 否则上层还会往死地址打")
        node.nodeState = .running
        node.reviveShouldFail = false
        node.carrierPath = .direct
        _ = await store.ensureReachable()
        XCTAssertTrue(store.phase == .ready && store.meshPath == .direct,
                      "N3b 探活可读 → 阶段保持 ready 且路径已刷新")

        // 路不通时不去重读一条死隧道，而是换一代 —— 判据是真实往返，不是节点自述。
        store.reachability = { _, _ in false }
        let retriedBefore = node.retriedConfigs.count
        _ = await store.ensureReachable()
        XCTAssertEqual(node.retriedConfigs.count, retriedBefore + 1,
                       "N3d 探活不通 → 重走一次注册（换代），不是在死路上重连")

        // —— 推送通道：节点侧状态变化回灌 store，投影据此重算 ——
        // 视图已不观察节点的 @Published；轮询探到的失败 / 路径切换必须经
        // onNodeChanged 推到 store，否则投影冻结在最近一次 store 调用的快照上。
        node.nodeState = .failed(.unreachable)
        node.carrierPath = nil
        node.onNodeChanged?()
        XCTAssertTrue(store.phase == .failed(.unreachable) && store.meshPath == nil,
                      "N3c 节点侧状态变化经 onNodeChanged 回灌：store 投影随即跟随（不经显式 store 调用）")
    }

    /// 产物换代：只在「上次已有产物、且新会话不是同一个」时报一次。
    ///
    /// 两个方向各有症状：报多了 —— 冷启动首次就绪被当成换代，刚建好的连接被拆掉重建，
    /// 用户看到「组网好了却连不上」还得等退避；从不报 —— 换了地址的连接继续握着旧会话
    /// 往旧地址打，而且不会有任何报错。
    ///
    /// 断言落在「拿到通知那一刻读到的 route」上：这个信号不带参数（route 是唯一真相），
    /// 接收方只能读它，所以必须证明那一刻它已经是新产物。
    func testRouteReplacedFiresOnlyWhenTheProductIsReplaced() async {
        let first = MeshConfig(controlURLString: "https://old.example:8443",
                               gatewayURLString: "http://100.64.0.1:3081")
        let second = MeshConfig(controlURLString: "https://new.example:8443",
                                gatewayURLString: "http://100.64.0.2:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        var order: [String] = []
        var baseURLAtFire: [URL?] = []
        store.onRouteReplaced = {
            order.append("route")
            baseURLAtFire.append(store.route?.baseURL)
        }
        store.onPhaseChanged = { _, _ in order.append("phase") }
        await store.start(config: first)

        // ① 首次就绪不是「替换」。
        order = []          // `start` 自己报过一次阶段（nil → needsSetup），那不是这条要看的东西
        let sessionA = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(sessionA)
        XCTAssertTrue(store.route?.session === sessionA,
                      "先确认产物真的建成了，否则下面测的是别的分支")
        XCTAssertEqual(order, ["phase"],
                       "首次就绪只报阶段 —— 报成换代会让刚建好的连接被拆掉再靠退避重连")

        // ② 换代：节点层先把状态打回接入中（`superseded` 那一支），新一代建成时
        //    产物与阶段在同一次回灌里都变。
        node.nodeState = .registering
        node.onNodeChanged?()
        _ = await store.submitMeshKey("hskey-auth-new", config: second)
        order = []          // 只看「产物建成」那一次回灌
        let sessionB = URLSession(configuration: .ephemeral)
        node.nodeState = .running
        node.onVerifiedRunning?(sessionB)

        XCTAssertTrue(store.route?.session === sessionB, "产物换成了新的")
        XCTAssertEqual(order, ["route", "phase"],
                       "先产物后阶段：反序会先用旧会话叫醒连接、紧接着又被拆掉 —— 一次白连")
        XCTAssertEqual(baseURLAtFire.last ?? nil, second.gatewayBaseURL,
                       "报的时候 route 必须已经是新地址 —— 接收方只能读它")

        // ③ 同一个会话再报一次不算换代（幂等重入会重放一次成功回调）。
        order = []
        node.onVerifiedRunning?(sessionB)
        XCTAssertTrue(order.isEmpty, "同一个会话重复报不算换代 —— 否则每条好连接都会被拆一次")
    }

    /// 提交与重试都直接转交节点层 —— store 自己没有拒绝分支。
    ///
    /// 这条原本断言「接入中提交被拒」。拒的代价是用户改完配置还得等旧那轮跑完（最长约
    /// 49 秒），而旧那轮恰恰是用户想作废的那一次；互相污染的顾虑由节点层代际收口
    /// （断言在 `TailnetNodeTests`）。
    ///
    /// 于是要证明的是「一定转交、且 store 的配置跟着换」—— 只落盘不转交，用户会以为改好了，
    /// 实际什么都没发生，也没有任何报错。
    func testSubmittingAndRetryingAreAlwaysForwarded() async {
        let old = MeshConfig(controlURLString: "https://old.example:8443",
                             gatewayURLString: "http://100.64.0.1:3081")
        let new = MeshConfig(controlURLString: "https://new.example:8443",
                             gatewayURLString: "http://100.64.0.2:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        await store.start(config: old)

        await store.submitMeshKey("hskey-auth-new", config: new)
        XCTAssertEqual(node.submitCount, 1, "提交要真的转交给节点层")

        await store.retryMesh(config: new)
        XCTAssertEqual(node.retriedConfigs, [new], "重试交的也是这一份")

        node.nodeState = .running
        node.onVerifiedRunning?(URLSession(configuration: .ephemeral))
        XCTAssertEqual(store.route?.baseURL, new.gatewayBaseURL,
                       "换代后的产物配新地址 —— 地址与传输同生共死")
    }

    /// 回前台的重试用**存下来的那份**配置，不是调用方手里的。
    ///
    /// 为什么值得一条：`retryStored()` 一旦收参数，编排就有两种传法，而传「手里的那份」
    /// 正是「旧 session 配上新地址」那类缺陷的入口。接口上少一个参数，这条就不必再靠人记。
    func testRetryingFromForegroundUsesTheStoredConfig() async {
        let stored = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        let node = FakeNode()
        let store = MeshStore(node: node)
        await store.start(config: stored)

        await store.retryStored()

        XCTAssertEqual(node.retriedConfigs, [stored], "重试用的是 start 时存下的那份")
    }
}

// MARK: - 假件（只实现 store 的注入面，不 import TailscaleKit / 不碰网络）

@MainActor private final class FakeNode: MeshNodeControlling, @unchecked Sendable {
    var nodeState: TailnetNodeState = .noKey
    var carrierPath: CarrierPath?
    var onVerifiedRunning: ((URLSession) -> Void)?
    var onNodeChanged: (() -> Void)?
    var reviveShouldFail = false
    var launchCount = 0
    var submitCount = 0
    var retriedConfigs: [MeshConfig] = []
    func launchNode(config: MeshConfig) async {
        launchCount += 1
    }
    func reviveNode() async {
        if reviveShouldFail { nodeState = .failed(.unreachable) }
        // 真实节点在状态迁移与路径刷新处推送（TailnetNode.transition / refreshPathNow）；
        // 假件在事实变化点同样推送，回灌链路才被测到。
        onNodeChanged?()
    }
    func submitKey(_ key: String, config: MeshConfig) async {
        // 计「转交次数」：这条是「一定真的交出去」的判据落点。
        submitCount += 1
    }
    func retry(config: MeshConfig) async {
        retriedConfigs.append(config)
    }
}
