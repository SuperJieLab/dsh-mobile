/**
 * 节点层自己的两条不变式：接入窗口（`isStarting`）怎么进、怎么出，以及窗口里不做探活。
 * 另有两条跨层判据（换代不交产物、产物的交付早于「就绪」），它们落在这里是因为
 * 决定顺序的是节点层，而假后端也只有这里造得出来。
 *
 * 这两条以前只在调用方那侧被测（`MeshStoreTests` 经 store 断言），而判据的归属错了：
 * 「节点还没验证过」只有节点知道。挪回来之后要能被测，就得让 `up()` 挂得住 ——
 * 于是有了 `TailnetBackend` 这条窄面（见 `Sources/Core/MeshNetwork/TailnetBackend.swift`）。
 *
 * 负控与正控必须成对：只断言「接入途中不读状态」，把 `revive()` 写成空函数也是绿的。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class TailnetNodeTests: XCTestCase {

    /// 假后端：可挂住 `up()`、可指定抛出、数 `statusJSON` 次数。
    ///
    /// 用 actor 而不是 `@MainActor` 类：`up()` 是在 `withTaskGroup` 的子任务里被调的，
    /// 那里的执行器与主线程无关 —— 共享计数器放在 actor 上才是真的安全。
    private actor FakeBackend: TailnetBackend {
        private(set) var statusCalls = 0
        private(set) var closeCalls = 0
        private var upCalls = 0
        private var holdsUp = false
        private var holdsClose = false
        private var failure: String?
        private var upWaiter: CheckedContinuation<Void, Never>?
        private var closeWaiter: CheckedContinuation<Void, Never>?

        func configure(holdsUp: Bool, failure: String? = nil, holdsClose: Bool = false) {
            self.holdsUp = holdsUp
            self.failure = failure
            self.holdsClose = holdsClose
        }

        func releaseUp() {
            upWaiter?.resume()
            upWaiter = nil
        }

        /// 放掉还可能挂着的 close 与 up —— 测试收尾用，免得留下悬挂的 continuation。
        func releaseEverything() {
            closeWaiter?.resume()
            closeWaiter = nil
            upWaiter?.resume()
            upWaiter = nil
        }

        /// 等第 `count` 次 `up()` 真的进来 —— 「窗口开着」不能靠 sleep 猜。
        ///
        /// **有界且按时间轮询**：纯 `Task.yield()` 的次数不够时（今天这条路上，起来之前要先
        /// 过一次 `supersede()` 的两次任务调度），循环会在后端还没造出来时就退出，于是后面的
        /// `releaseUp()` 变成空操作、`await` 那一侧永远等不到 —— 挂死不算红，它只是把
        /// 「断言失败」换成了「永远没结论」。用 `Task.sleep` 让出执行权，比 yield 可靠。
        @discardableResult
        func waitUntilUpCalls(_ count: Int, timeoutMs: Int = 3000) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if upCalls >= count { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return upCalls >= count
        }

        /// 等 `close()` 被调到第 `count` 次 —— 「作废这一步已经开始」不能靠 sleep 猜。
        @discardableResult
        func waitUntilCloseCalls(_ count: Int, timeoutMs: Int = 3000) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if closeCalls >= count { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return closeCalls >= count
        }

        func statusJSONCalls() -> Int { statusCalls }

        func up() async throws {
            upCalls += 1
            if holdsUp {
                await withCheckedContinuation { upWaiter = $0 }
            }
            if let failure { throw FakeUpFailure(message: failure) }
        }

        /// 与上游同形：`close()` 是解开卡住的 `up()` 的那一下，且它自己可能不返回。
        func close() async throws {
            closeCalls += 1
            upWaiter?.resume()
            upWaiter = nil
            if holdsClose {
                await withCheckedContinuation { closeWaiter = $0 }
            }
        }

        func statusJSON() async throws -> Data {
            statusCalls += 1
            return Data(#"{"BackendState":"Running","Peer":{}}"#.utf8)
        }

        func makeGatewaySession() async throws -> URLSession {
            URLSession(configuration: .ephemeral)
        }
    }

    private struct FakeUpFailure: Error {
        let message: String
        var localizedDescription: String { message }
    }

    /// 上游的错误归类靠消息文本（`outcome(forMessage:)`）—— 结构化的假错误必须让它
    /// 在 `String(describing:)` 里带上 `authkey`，否则会落到「可重试」那条，白等两次退避。
    private func completeConfig() -> MeshConfig {
        MeshConfig(controlURLString: "https://203.0.113.10:8443",
                   gatewayURLString: "http://100.64.0.1:3081")
    }

    /// 落盘的那一格不是断言对象：`submitKey` 会写它，用完恢复原值，别把模拟器上配好的 key 覆盖掉。
    private var savedKey: String?

    override func setUp() {
        super.setUp()
        savedKey = TailnetNode.TailnetKeyStore.load()
    }

    override func tearDown() {
        if let savedKey {
            TailnetNode.TailnetKeyStore.save(savedKey)
        } else {
            SecretFile.delete("tailnet-key")
        }
        super.tearDown()
    }

    // MARK: - B2

    /// 接入途中不探活；接入结束后照常探活。
    ///
    /// 症状不是「慢一点」—— 探活读的是 `statusJSON`，节点此刻还没验证过，读失败会把状态
    /// 打成 `failed(unreachable)`；而 `.failed` 之后成功进不来（迁移表里没有那一格），
    /// 于是一次正常接入被一次切后台彻底废掉。
    ///
    /// 正控那一半是这条的一半：没有它，把 `revive()` 写成空函数也绿。
    func testReviveDoesNotProbeWhileTheNodeIsStarting() async {
        let backend = FakeBackend()
        let node = TailnetNode(makeBackend: { _ in backend })
        let config = completeConfig()

        // 第一条 up 走完成功路径：状态 running、session 建成 —— 这才有「探活」可言。
        await node.submitKey("hskey-auth-first", config: config)
        XCTAssertEqual(node.state, .running)
        XCTAssertFalse(node.isStarting)

        // 轮询的首轮会立刻读两次状态。等它读完再取基线，否则基线会平移。
        await waitForPathPollingFirstRound(backend)

        // 第二条 up：running 状态下再提交 key —— 换代把它如实打回「接入中」，
        // 而节点正在起。窗口仍在（`isStarting`），但不再有「状态说已就绪、其实没验证过」的错位：
        // 那个错位是旧行为，换代时先 `superseded` 就是为消除它。
        await backend.configure(holdsUp: true)
        let second = Task { await node.submitKey("hskey-auth-second", config: config) }
        await backend.waitUntilUpCalls(2)

        XCTAssertTrue(node.isStarting, "窗口开着")
        XCTAssertEqual(node.state, .registering, "换代时状态如实回到接入中 —— 不留「说 running、其实在起」的错位")

        let baseline = await backend.statusJSONCalls()
        await node.revive()
        let duringStart = await backend.statusJSONCalls()
        XCTAssertEqual(duringStart, baseline,
                       "接入途中不该读状态 —— 读失败会把一次正常接入打成不可达")

        await backend.releaseUp()
        _ = await second.value
        XCTAssertFalse(node.isStarting, "接入结束，窗口收")

        let beforeProbe = await backend.statusJSONCalls()
        await node.revive()
        let afterProbe = await backend.statusJSONCalls()
        XCTAssertGreaterThan(afterProbe, beforeProbe,
                             "接入结束后探活要真的读状态 —— 否则这条判据只是在守一个空函数")
    }

    // MARK: - B3

    /// 接入窗口的进出都靠 `defer`：抛出要复位，正常返回也要复位。
    ///
    /// 漏一条就永久卡在忙 —— 之后每次提交都被拒，而界面只会说「正在接入」。
    func testTheStartingFlagIsClearedOnBothEndsOfTheWindow() async {
        let backend = FakeBackend()
        let node = TailnetNode(makeBackend: { _ in backend })
        let config = completeConfig()

        // 出口一：up() 抛出（key 被拒 = 不重试，一次结束）。
        await backend.configure(holdsUp: false, failure: "invalid authkey")
        await node.submitKey("hskey-auth-bad", config: config)
        XCTAssertFalse(node.isStarting, "抛出之后窗口要收")
        XCTAssertEqual(node.state, .failed(.badKey), "按消息归类成 key 被拒")

        // 出口二：up() 正常返回。
        await backend.configure(holdsUp: true)
        let second = Task { await node.submitKey("hskey-auth-good", config: config) }
        await backend.waitUntilUpCalls(2)
        XCTAssertTrue(node.isStarting, "挂着时窗口开着")

        await backend.releaseUp()
        _ = await second.value
        XCTAssertFalse(node.isStarting, "返回之后窗口要收")
    }

    /// 让路径轮询的首轮跑完 —— 它一启动就立刻读两次状态（后端事实 + 路径）。
    ///
    /// 按次数等，不按时间等：一次成功接入里 `statusJSON` 的确定性次数是 4
    /// （`up()` 里两次：先看 BackendState、再确认 Running；轮询首轮两次：后端事实 + 路径）。
    /// 不等它，基线会在断言期间平移，负控就变成假红。
    private func waitForPathPollingFirstRound(_ backend: FakeBackend) async {
        for _ in 0..<200 {
            let calls = await backend.statusJSONCalls()
            if calls >= 4 { return }
            await Task.yield()
        }
    }

    // MARK: - 换代：旧一代被取代后，它的结论不再算数

    /// 按 key 分派假后端：两代交错时要能分辨「旧那一个」与「新那一个」。
    private func twoBackends(_ old: FakeBackend, _ fresh: FakeBackend) -> BackendFactory {
        { spec in spec.authKey == "hskey-auth-old" ? old : fresh }
    }

    /// 旧那一代还挂着时提交新 key：旧的要被 close 掉，最终状态来自新那一代。
    func testSubmittingAgainSupersedesTheAttemptStillRunning() async {
        let old = FakeBackend()
        await old.configure(holdsUp: true)
        let fresh = FakeBackend()
        let node = TailnetNode(makeBackend: twoBackends(old, fresh))
        let config = completeConfig()

        let first = Task { await node.submitKey("hskey-auth-old", config: config) }
        await old.waitUntilUpCalls(1)
        XCTAssertTrue(node.isStarting, "第一代正在起")

        await node.submitKey("hskey-auth-fresh", config: config)

        let closes = await old.closeCalls
        XCTAssertEqual(closes, 1, "旧那一代必须被 close —— 上游唯一的取消手段")
        XCTAssertEqual(node.state, .running, "最终状态来自新一代")
        XCTAssertFalse(node.isStarting, "窗口在新一代结束后收")

        await old.releaseEverything()
        _ = await first.value
    }

    /// 迟到的结论不得改写当代的结果：旧那一代被 close 后抛出 badKey，界面不能因此变成失败。
    ///
    /// 断言的落点选在末尾，且**先让旧那一代把自己那条路走完**（`releaseEverything` + 等它返回），
    /// 再读状态 —— 这样「若没判代际就写 failed」这件事一定已经发生过，断言不靠时序赌。
    func testTheSupersededAttemptCannotOverwriteTheResult() async {
        let old = FakeBackend()
        await old.configure(holdsUp: true, failure: "invalid authkey")
        let fresh = FakeBackend()
        await fresh.configure(holdsUp: true)
        let node = TailnetNode(makeBackend: twoBackends(old, fresh))
        let config = completeConfig()

        let first = Task { await node.submitKey("hskey-auth-old", config: config) }
        await old.waitUntilUpCalls(1)

        let second = Task { await node.submitKey("hskey-auth-fresh", config: config) }
        await fresh.waitUntilUpCalls(1)

        await fresh.releaseUp()
        _ = await second.value
        await old.releaseEverything()
        _ = await first.value

        XCTAssertEqual(node.state, .running,
                       "旧一代迟到的 badKey 不得改写新一代的结果 —— 它的结论在换代那一刻就作废了")
    }

    /// 旧那一代迟到的**成功**也不得交出产物 —— 这条比「不写状态」更要紧。
    ///
    /// 状态写错是一格标签；产物交出去，调用方就会把它与此刻的组网配置拼成一对
    /// （旧 session + 新地址），请求会全部打在「那条会话到不了的地方」，而且没有任何报错。
    ///
    /// 构造上不赌时序：旧一代的 `up()` 正是被 `close()` 解开的，所以它走完成功那条路
    /// 恰好发生在换代过程当中 —— 那是真实路径，不是人为插进去的。
    func testTheSupersededAttemptCannotHandOutItsProduct() async {
        let old = FakeBackend()
        await old.configure(holdsUp: true)
        let fresh = FakeBackend()
        let node = TailnetNode(makeBackend: twoBackends(old, fresh))
        let config = completeConfig()

        var handedOut: [URLSession] = []
        node.onVerifiedRunning = { handedOut.append($0) }

        let first = Task { await node.submitKey("hskey-auth-old", config: config) }
        await old.waitUntilUpCalls(1)

        let second = Task { await node.submitKey("hskey-auth-fresh", config: config) }
        await fresh.waitUntilUpCalls(1)
        await fresh.releaseUp()
        _ = await second.value
        _ = await first.value

        XCTAssertEqual(handedOut.count, 1,
                       "只有新一代交产物 —— 旧一代迟到的成功再交一次，就有人拿旧 session 配新地址")
        XCTAssertEqual(node.state, .running, "状态同样只来自新一代")
    }

    /// 产物的交付必须早于「就绪」的宣布 —— 在**真装配**上验，不靠两端各自的假件。
    ///
    /// 两端各自的判据都绿也可能坏：换代的判断在 store，而「什么时候算就绪」由节点决定。
    /// 节点若先 `transition(`Running`)` 再交产物，store 那次回灌读到的 `route` 还是上一代的
    /// 会话 —— 于是它先报一次「就绪」，接收方拿旧会话连一次，紧接着才被告知换代并拆掉。
    ///
    /// 这条判据的形状是「事件序列」，不是「谁被调过」：只有序列能分辨那一次白连。
    func testTheProductIsHandedOutBeforeReadyIsAnnounced() async {
        let backend = FakeBackend()
        let node = TailnetNode(makeBackend: { _ in backend })
        let store = MeshStore(node: node)
        let config = completeConfig()
        var order: [String] = []
        store.onRouteReplaced = { order.append("route") }
        // 只收「就绪」这一种阶段：中途的 connecting 不在本判据的观察范围内。
        store.onPhaseChanged = { _, new in if case .ready = new { order.append("phase:ready") } }

        // `launch` 要先有 key 才会真的去起节点（没有 key 就停在 noKey，`up()` 都不会跑）。
        TailnetNode.TailnetKeyStore.save("hskey-auth-first")
        await store.start(config: config)
        XCTAssertEqual(order, ["phase:ready"],
                       "首次就绪只报阶段 —— 报成换代等于让接收方去拆一条还不存在的连接")

        // 换代：新的一次接入建成。
        order = []
        await store.submitMeshKey("hskey-auth-second", config: config)
        XCTAssertEqual(order, ["route", "phase:ready"],
                       "先产物、后阶段。反序会让接收方先拿旧会话叫醒一次连接，再把它拆掉")
    }

    /// 连点两次保存、第一次的 close 还挂着：两代**不许**并到同一个代号上。
    ///
    /// 触发条件不是纸面情形 ——「已有节点 + close 挂住」正是控制面不可达时的样子，而
    /// `close` 的等待上限就是两秒。若代号由 `up()` 自己在入口读，那两个提交都会读到最后的
    /// 值：两代通吃同一代号，各自都能交产物、都能写状态，用户看到的是「点了两次，结果不确定」。
    ///
    /// 断言的落点是**交产物的次数**：只有最后那一次提交该交。
    ///
    /// 修法有两处守卫（close 之后判一次当代、代号由提交方带进 `up()`），它们互为冗余：
    /// 单独去掉任何一个这条仍然绿，**两个都去掉才红**（变异探针实测 2 ≠ 1）。
    /// 记这一点是为了别人别以为「删了一个还绿」就等于那一行没用。
    func testASecondSubmitWhileTheFirstCloseHangsDoesNotShareTheGeneration() async {
        let base = FakeBackend()            // 已入网的那个节点：换代时它的 close 挂住
        let first = FakeBackend()           // 第一次提交（会被取代）
        let second = FakeBackend()          // 第二次提交（该赢）
        let node = TailnetNode(makeBackend: { spec in
            switch spec.authKey {
            case "hskey-auth-base": return base
            case "hskey-auth-first": return first
            default: return second
            }
        })
        let config = completeConfig()
        var handedOut: [URLSession] = []
        node.onVerifiedRunning = { handedOut.append($0) }

        // 先让组网就绪，后面两次提交才会各有一次「关掉上一个节点」。
        await node.submitKey("hskey-auth-base", config: config)
        XCTAssertEqual(node.state, .running, "先确认起点真的入网了，否则下面测的是别的路径")
        handedOut = []

        // 此后这个节点关不掉 —— close 会一直等到上限。
        await base.configure(holdsUp: false, holdsClose: true)

        let a = Task { await node.submitKey("hskey-auth-first", config: config) }
        await base.waitUntilCloseCalls(1)   // A 的作废动作真的开始了

        let b = Task { await node.submitKey("hskey-auth-second", config: config) }
        _ = await a.value
        _ = await b.value

        XCTAssertEqual(handedOut.count, 1,
                       "只有最后一次提交该交产物 —— 交两次说明两代共用了同一个代号")
        XCTAssertEqual(node.state, .running, "终局来自后那一代")
        XCTAssertEqual(TailnetNode.TailnetKeyStore.load(), "hskey-auth-second",
                       "盘上该是后点的那次 —— 先点的那次等完 close 再写就会把它覆盖掉")
    }

    /// `close()` 自己不返回时，新一代仍要能开始 —— 否则「打断」只是把等待换了个位置。
    func testAStuckCloseStillLetsTheNextAttemptStart() async {
        let old = FakeBackend()
        await old.configure(holdsUp: true, holdsClose: true)
        let fresh = FakeBackend()
        let node = TailnetNode(makeBackend: twoBackends(old, fresh))
        let config = completeConfig()

        let first = Task { await node.submitKey("hskey-auth-old", config: config) }
        await old.waitUntilUpCalls(1)

        let startedAt = Date()
        await node.submitKey("hskey-auth-fresh", config: config)
        let waited = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(waited, 1.9,
                                    "close 挂住时应当等满上限再放手，而不是无限期等它")
        XCTAssertEqual(node.state, .running, "新一代照常起 —— 新一代的成败不受旧一代卡住影响")

        await old.releaseEverything()
        _ = await first.value
    }

    // MARK: - 状态目录健康判定

    /// 启动路径上的一个判定，三条分支各有后果 —— 它决定「重开不重注册」还是「重新注册」。
    ///
    /// 三条都要断言：只测「可读 → true」的话，把整个函数写成 `return true` 也绿；
    /// 而那个错法在真机上表现为「拿半份身份去起节点，起不来还看不出为什么」。
    func testStateStoreHealthTellsTheThreeCasesApart() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dsh-state-health-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // ① 不存在 = 干净首启。
        XCTAssertFalse(TailnetNode.stateStoreHealthy(in: root), "目录不存在：视为未注册")

        // ② 存在且可读 = 重开不重注册。
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(TailnetNode.stateStoreHealthy(in: root), "可读的目录：视为已注册")

        // ③ 存在但不是目录 = 半途写坏，fail-closed。
        let file = root.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(TailnetNode.stateStoreHealthy(in: file), "同名文件不是状态目录")

        // ④ 存在但读不了 = 写坏，fail-closed。
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        XCTAssertFalse(TailnetNode.stateStoreHealthy(in: root), "不可读：视为未注册")
        // 还原权限，否则 defer 里的删除也会失败（留一个空目录在临时区）。
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    }
}
