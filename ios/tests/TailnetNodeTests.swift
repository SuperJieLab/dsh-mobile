/**
 * 节点层自己的两条不变式：接入窗口（`isStarting`）怎么进、怎么出，以及窗口里不做探活。
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
        _ = await node.submitKey("hskey-auth-first", config: config)
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
        _ = await node.submitKey("hskey-auth-bad", config: config)
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

        _ = await node.submitKey("hskey-auth-fresh", config: config)

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
        _ = await node.submitKey("hskey-auth-fresh", config: config)
        let waited = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(waited, 1.9,
                                    "close 挂住时应当等满上限再放手，而不是无限期等它")
        XCTAssertEqual(node.state, .running, "新一代照常起 —— 新一代的成败不受旧一代卡住影响")

        await old.releaseEverything()
        _ = await first.value
    }
}
