/**
 * 列表宿主的**交错**行为：一次拉取与几条变更撞在一起时，列表最后长什么样。
 *
 * 合并本身在 `SessionListMergerTests`（纯值类型）；这里测的是它之外那三件事：
 * 在途期间到达的变更（记账 + 立即生效）、两次拉取并发（单飞）、源换代次（重拉）。
 *
 * 判据都要能看见「请求发了几次」，所以取数与事件都是替身：真 socket 在这里只会把
 * 「哪一次请求落到谁的账上」混进网络的偶然。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionListStateTests: XCTestCase {

    /// 一条会话行。只有 `updatedAt` 与标题参与本组判据。
    private func row(_ id: String, title: String? = nil, updatedAt: Double) -> SessionSummary {
        SessionSummary(
            id: id, title: title, createdAt: 1, updatedAt: updatedAt,
            running: false, blank: false, origin: nil, workspaceId: nil
        )
    }

    /// 可停住、可计数的取数。第一次调用会挂在 `gate` 上直到测试放行 ——
    /// 「在途」必须是一个能被握住的时刻，不能靠 sleep 撞。
    @MainActor
    private final class FakeFetch {
        private(set) var calls = 0
        var rows: Result<[SessionSummary], Error> = .success([])
        /// 组清单。多数用例不关心分组，默认空 —— 那时全部会话落「未分组」。
        var workspaces: [WorkspaceSummary] = []
        var holds = true
        private var gate: CheckedContinuation<Void, Never>?

        func fetch() async throws -> SessionListPage {
            calls += 1
            if holds {
                holds = false   // 只停第一次：单飞的那一条要证明第二次根本没发出去
                await withCheckedContinuation { gate = $0 }
            }
            return SessionListPage(sessions: try rows.get(), workspaces: workspaces)
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    private func change(_ payload: String) throws -> SessionListChange {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        return try XCTUnwrap(SessionListChange.decode(value), "这条样本该解得出：\(payload)")
    }

    /// 这一组里的多数用例不碰写动作（建会话 / 建工作空间 / 删工作空间）：三个都默认给一个
    /// 「被调到就失败」的桩，用到了再显式传。
    private struct WriteNotExpected: Error {}

    private func make(
        _ fetch: FakeFetch,
        create: @escaping (String?) async throws -> String = { _ in throw WriteNotExpected() },
        createWorkspace: @escaping (String) async throws -> WorkspaceCreated = { _ in throw WriteNotExpected() },
        deleteWorkspace: @escaping (String) async throws -> Void = { _ in throw WriteNotExpected() },
        open: @escaping (String) -> Void = { _ in },
        expansion: GroupExpansion = GroupExpansion(),
        persisted: @escaping (GroupExpansion) -> Void = { _ in }
    ) -> SessionListState {
        SessionListState(fetch: { try await fetch.fetch() }, create: create,
                         createWorkspace: createWorkspace, deleteWorkspace: deleteWorkspace,
                         open: open, expansion: expansion, persistExpansion: persisted)
    }

    /// 让挂起的任务跑到它的第一个 await。
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - L6 单飞

    /// 两次 `reload()` 撞在一起：取数只被调一次，两次都拿到同一份结果。
    func testConcurrentReloadsShareOneRequest() async {
        let fetch = FakeFetch()
        fetch.rows = .success([row("a", updatedAt: 100)])
        let state = make(fetch)

        let first = Task { await state.reload() }
        await settle()
        let second = Task { await state.reload() }
        await settle()

        XCTAssertEqual(fetch.calls, 1, "在途时不该起第二次请求")
        fetch.release()
        await first.value
        await second.value

        XCTAssertEqual(state.sessions.map(\.id), ["a"])
        XCTAssertEqual(fetch.calls, 1)
    }

    /// 一次拉取落地之后再拉，是**新的**一次（单飞只压并发，不压先后）。
    func testASecondReloadAfterTheFirstLandedHitsTheNetworkAgain() async {
        let fetch = FakeFetch()
        fetch.holds = false
        let state = make(fetch)

        await state.reload()
        await state.reload()
        XCTAssertEqual(fetch.calls, 2)
    }

    // MARK: - L1 事件不是基线

    /// 事件造出来的行，在基线落地之后**不被保留** —— 这是「事件不是基线」唯一可观察的形式。
    ///
    /// 只断「apply 会加一行」是不区分两种设计的：任何实现都通过。真正区分的是下一步：
    /// 拉取拿回一份**不含它**的列表，它必须消失（它不在基线里，而那一发在途时它还没到，
    /// 所以也没有账可以把它重放回来）。
    func testARowThatOnlyAnEventKnewAboutDoesNotSurviveTheBaseline() async throws {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.rows = .success([row("a", updatedAt: 100)])
        let state = make(fetch)

        state.apply(try change(#"{"kind":"added","row":{"id":"b","updatedAt":300,"running":false,"blank":false}}"#))
        XCTAssertEqual(state.sessions.map(\.id), ["b"], "事件先到：列表只有它")

        await state.reload()
        XCTAssertEqual(state.sessions.map(\.id), ["a"], "基线说了算：b 不在里面，就该消失")
    }

    // MARK: - L2 在途期间的变更

    /// 刷新在途时来了两条变更（新增 B、A 有活动）：落地后两条都在，且顺序按时间。
    ///
    /// 这是本期唯一真正新的行为：整表替换会把它俩抹掉。
    /// 前提是列表**已经有一份**（回前台 / 下拉都发生在有内容之后）—— `activity` 与
    /// `status` 对未知 id 不造行（它们说的是「已经有一行」的事），所以初始必须为空之外的状态。
    func testChangesThatArriveWhileAPullIsInFlightSurviveIt() async throws {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.rows = .success([row("a", updatedAt: 100), row("z", updatedAt: 50)])
        let state = make(fetch)
        await state.reload()

        fetch.holds = true
        let pull = Task { await state.reload() }
        await settle()

        state.apply(try change(#"{"kind":"added","row":{"id":"b","updatedAt":300,"running":false,"blank":false}}"#))
        state.apply(try change(#"{"kind":"activity","id":"a","updatedAt":200}"#))
        // 在途期间就已经生效：用户不必等这一发回来才看见。
        XCTAssertEqual(state.sessions.map(\.id), ["b", "a", "z"], "立即生效，而不是攒着等")

        fetch.release()
        await pull.value

        XCTAssertEqual(state.sessions.map(\.id), ["b", "a", "z"],
                       "响应落地后重放：新增的 B 与推新的 A 都要在")
        XCTAssertEqual(state.sessions.map(\.updatedAt), [300, 200, 50])
    }

    /// 在途期间删掉一行，响应里还有它：账重放之后它不该复活。
    func testARemovalThatArrivesWhileAPullIsInFlightWins() async throws {
        let fetch = FakeFetch()
        fetch.rows = .success([row("a", updatedAt: 100), row("b", updatedAt: 50)])
        let state = make(fetch)

        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change(#"{"kind":"removed","id":"a"}"#))

        fetch.release()
        await pull.value

        XCTAssertEqual(state.sessions.map(\.id), ["b"], "删除压过拉取")
    }

    /// 响应里也有同一条新行：仍然只有一行。
    func testARowThatBothTheEventAndTheResponseCarryIsOneRow() async throws {
        let fetch = FakeFetch()
        fetch.rows = .success([row("b", title: "拉取来的", updatedAt: 300)])
        let state = make(fetch)

        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change(#"{"kind":"added","row":{"id":"b","updatedAt":300,"running":false,"blank":false}}"#))

        fetch.release()
        await pull.value

        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.sessions[0].id, "b")
    }

    // MARK: - 可见性：两条路同一道筛

    /// 事件推来的 `blank` 行不进列表 —— 与拉取给的行同一条规则。
    ///
    /// 「在 Mac 上点了一下新建、还没说话」是最常见的形态：不筛的话手机会立刻多出一行
    /// 「（无标题）」，下拉之后又消失，页脚计数也跟着错。
    func testInvisibleRowsFromEventsNeverEnterTheList() throws {
        let state = make(FakeFetch())
        state.apply(try change("""
        {"kind":"added","row":{"id":"s1","updatedAt":100,"running":false,"blank":true}}
        """))
        XCTAssertTrue(state.sessions.isEmpty, "blank 行不显示")

        state.apply(try change("""
        {"kind":"added","row":{"id":"s2","updatedAt":90,"running":false,"blank":false,"origin":"subagent"}}
        """))
        XCTAssertTrue(state.sessions.isEmpty, "子会话不显示")

        state.apply(try change(#"{"kind":"added","row":{"id":"s3","updatedAt":80,"running":false,"blank":false}}"#))
        XCTAssertEqual(state.sessions.map(\.id), ["s3"], "普通行照常出现")
    }

    /// 在途期间到达的不可见行，重放之后也不该漏进来 —— 落地后要再筛一次。
    func testAnInvisibleRowBufferedDuringAPullDoesNotLeakOnReplay() async throws {
        let fetch = FakeFetch()
        fetch.rows = .success([row("a", updatedAt: 100)])
        let state = make(fetch)

        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change("""
        {"kind":"added","row":{"id":"b","updatedAt":300,"running":false,"blank":true}}
        """))
        fetch.release()
        await pull.value

        XCTAssertEqual(state.sessions.map(\.id), ["a"], "重放不该把 blank 行加回来")
    }

    // MARK: - 装配：一帧从事件流走到列表

    /// 一整跳：事件流上收到一帧列表增量，列表就变了。
    ///
    /// 这一条守的是**接线**，不是任何一端的行为 —— 判读器认识它、`apply` 也会改行，
    /// 但没人把两者接起来时，前两组判据全绿而列表一动不动。两端各守一半、中间那一跳
    /// 没人守，是这个仓库反复踩到的一种缺口。
    func testAFrameOnTheEventStreamReachesTheList() throws {
        let state = make(FakeFetch())
        let events = EventStream()
        state.attach(events: events)

        let data = Data("""
        {"type":"item","streamId":"e1","payload":{"kind":"session-list","change":{
          "kind":"added","row":{"id":"s1","updatedAt":100,"running":false,"blank":false}}}}
        """.utf8)
        events.handle(EventReader.read(try XCTUnwrap(InboundFrame.decode(data))))

        XCTAssertEqual(state.sessions.map(\.id), ["s1"], "这一帧该一路走到列表上")
    }

    /// 认不出的列表增量在消费方丢弃：坏形状不进合并器，列表不动。
    ///
    /// 丢弃口径归消费方 —— 「认不出怎么办」是读法的一部分：列表的口径是跳过这一条继续。
    func testMalformedListChangeIsDroppedAtTheConsumer() throws {
        let state = make(FakeFetch())
        let events = EventStream()
        state.attach(events: events)

        for text in [
            #"{"type":"item","streamId":"e1","payload":{"kind":"session-list"}}"#,
            #"{"type":"item","streamId":"e1","payload":{"kind":"session-list","change":{"kind":"question"}}}"#,
        ] {
            let frame = try XCTUnwrap(InboundFrame.decode(Data(text.utf8)), "这一帧该解得开：\(text.prefix(80))")
            events.handle(EventReader.read(frame))
        }
        XCTAssertTrue(state.sessions.isEmpty, "认不出的增量一条都不该进列表")
    }

    // MARK: - L8 失败不清空

    /// 拉取失败：列表保留原样，事件带来的变化也仍在，失败面照常报。
    func testAFailedPullKeepsTheListAndTheChanges() async throws {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.rows = .success([row("a", updatedAt: 100)])
        let state = make(fetch)
        await state.reload()

        // 第二发要真的停在在途：不这样的话，`apply` 落在失败之后，这条就退化成
        // 「失败不清空 + apply 会改行」，而后半是 apply 的定义。
        fetch.rows = .failure(RpcClientError.notActivated)
        fetch.holds = true
        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change(#"{"kind":"activity","id":"a","updatedAt":500}"#))
        fetch.release()
        await pull.value

        XCTAssertEqual(state.sessions.map(\.id), ["a"], "失败不清空")
        XCTAssertEqual(state.sessions[0].updatedAt, 500, "失败之后事件仍然生效")
        XCTAssertEqual(state.blockedReason, "组网尚未就绪 —— 等连接建立后再试。",
                       "前置不满足归中性提示，且文案是服务端原文")
    }

    // MARK: - L8b 三种面分得开

    /// 两种前置说成两句不同的话 —— 服务端原文已经区分了，端上不再猜。
    func testPrerequisitesAreNotFailures() async {
        for (error, expected) in [(RpcClientError.notActivated, "组网尚未就绪 —— 等连接建立后再试。"),
                                  (RpcClientError.unauthenticated, "还没有配对，或配对已被 Mac 侧撤销 —— 请重新配对。")] {
            let fetch = FakeFetch()
            // 不挂起：这几个用例只关心落成的面，不关心在途期间发生了什么。
            fetch.holds = false
            fetch.rows = .failure(error)
            let state = make(fetch)
            await state.reload()

            XCTAssertEqual(state.blockedReason, expected, "\(error) 该落成中性提示")
            XCTAssertNil(state.failureText, "\(error) 不该是红条 —— 用户没做错事")
        }
    }

    /// 传输失败是真失败：红条，且不是「还差一步配置」。
    func testTransportFailureIsAFailure() async {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.rows = .failure(RpcClientError.transport(
            url: URL(string: "http://100.64.0.1:3081/rpc")!,
            underlying: URLError(.cannotConnectToHost)))
        let state = make(fetch)
        await state.reload()

        XCTAssertNotNil(state.failureText, "传输失败要红条")
        XCTAssertNil(state.blockedReason, "别把网络问题说成配置问题 —— 用户会去改一件没坏的东西")
    }

    /// 分类只看错误类型，不推算「现在缺什么」。
    ///
    /// 三个反例各是一种「看起来像前置、其实不是」的错误：状态码、协议拒绝、响应坏掉。
    /// 它们都不该被归进中性提示 —— 那会让用户去设置里找一个不存在的开关。
    func testOnlyTwoErrorsArePrerequisites() {
        XCTAssertTrue(SessionListState.isPrerequisite(.notActivated))
        XCTAssertTrue(SessionListState.isPrerequisite(.unauthenticated))
        XCTAssertFalse(SessionListState.isPrerequisite(.badStatus(503)))
        XCTAssertFalse(SessionListState.isPrerequisite(
            .refused(GatewayFailure(code: "invalid-request", message: "x"))))
        XCTAssertFalse(SessionListState.isPrerequisite(.malformedResponse(detail: "x")))
    }

    // MARK: - L7 换代次重拉

    /// 事件流每报到一次（含重连拿到相同代次），就重拉一次 —— 这条流不重放，
    /// 「两次报到之间的事件可能丢了」在客户端唯一可观察的形式就是它。
    func testEveryGenerationReportPullAgain() async throws {
        let fetch = FakeFetch()
        fetch.holds = false
        let state = make(fetch)
        let events = EventStream()
        state.attach(events: events)

        events.handle(EventReading(content: .ready(generation: 3)))
        await settle()
        XCTAssertEqual(fetch.calls, 1, "第一次 ready")

        events.handle(EventReading(content: .ready(generation: 3)))
        await settle()
        XCTAssertEqual(fetch.calls, 2, "重连拿到相同代次也是新的开始")

        events.handle(EventReading(content: .ready(generation: nil)))
        await settle()
        XCTAssertEqual(fetch.calls, 3, "源失效也要重拉：那些事件再也补不回来")
    }

    // MARK: - 新建会话

    /// 建成的 id 交给 `open`，且**不碰列表**。
    ///
    /// 断言「列表没变」不是形式：新建出来的一定是 `blank`，而 `blank` 被
    /// `SessionVisibility` 筛掉，所以在这里顺手 `reload()` 是一次**注定读不到**的读 ——
    /// 它既白花一次请求，又会让「点了新建但列表还空着」看起来像失败。
    func testCreatingOpensTheNewSessionAndLeavesTheListAlone() async {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.rows = .success([row("a", updatedAt: 100)])
        var opened: [String] = []
        let state = make(fetch, create: { _ in "session-new" }, open: { opened.append($0) })
        await state.reload()
        let before = state.sessions.map(\.id)

        await state.createSession(in: nil)

        XCTAssertEqual(opened, ["session-new"], "宿主给的 id 要交给 open —— 那是导航的唯一输入")
        XCTAssertEqual(state.sessions.map(\.id), before, "新建不许动列表")
        XCTAssertEqual(fetch.calls, 1, "新建之后再读一次列表是白读，不该发生")
        XCTAssertFalse(state.isCreating, "动作结束后在飞标记要落")
    }

    /// 在飞期间再点一次：**不发起第二发**，也只推进一屏。
    ///
    /// 上游对空会话有复用规则，连点不会堆出两个会话 —— 但那是宿主的规则，不该拿来兜 UI：
    /// 两发会让两个动作抢同一行状态，且各自都会推进一屏。
    func testASecondCreateWhileOneIsInFlightIsIgnored() async {
        var calls = 0
        var opened: [String] = []
        let gate = CreateGate()
        let state = make(FakeFetch(), create: { _ in
            calls += 1
            return try await gate.wait()
        }, open: { opened.append($0) })

        let first = Task { await state.createSession(in: nil) }
        await settle()
        // 第二次也丢进 Task：**在飞**这件事本身就意味着它会挂住，同步 await 会把
        // 「去掉守卫」这个变异变成一个挂死而不是一条红的断言。
        let second = Task { await state.createSession(in: nil) }
        await settle()

        XCTAssertEqual(calls, 1, "在飞时不该发起第二次")

        gate.release("session-new")
        await first.value
        await second.value
        XCTAssertEqual(opened, ["session-new"], "只该推进一屏")
    }

    /// 宿主拒绝：不推进、不静默，把说法落到失败面。
    func testAFailedCreateSurfacesTheFailureAndOpensNothing() async {
        var opened: [String] = []
        let state = make(FakeFetch(), create: { _ in throw RpcClientError.badStatus(500) },
                         open: { opened.append($0) })

        await state.createSession(in: nil)

        XCTAssertTrue(opened.isEmpty, "没建成就不该有导航目标")
        XCTAssertNotNil(state.failureText, "失败要给说法")
        XCTAssertFalse(state.isCreating)
    }

    /// 可放行的创建桩：把「在飞」变成一个能握住的时刻。
    @MainActor
    private final class CreateGate {
        /// **多个等待者**：若哪个变异真的放进了第二次调用，它们会一起挂在这里；
        /// 只留一个的话第二个会覆盖第一个，导致「挂死」而不是断言失败。
        private var waiters: [CheckedContinuation<String, Error>] = []

        func wait() async throws -> String {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func release(_ id: String) {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume(returning: id) }
        }
    }

    // MARK: - 在某个工作空间里建会话、造工作空间

    /// 组内新建：客户端把那个组的 id 原样交给宿主。
    ///
    /// 这条守的是「点 A 组建的会话跑到 B 组」—— 那不会有任何编译错，只会在第一次发言之后
    /// 让人发现会话不在自己点的那个组里。
    func testCreatingASessionCarriesTheWorkspaceItWasAskedFor() async {
        var asked: [String?] = []
        let state = make(FakeFetch(),
                         create: { workspaceId in
                             asked.append(workspaceId)
                             return "s-new"
                         },
                         open: { _ in })

        await state.createSession(in: "w-a")

        XCTAssertEqual(asked, [Optional("w-a")], "手机点的那个组必须原样传下去")
    }

    /// 造工作空间成功：名字先 trim，成功后必须重拉 —— 组清单只在拉取时更新。
    func testCreatingAWorkspaceReloadsSoTheNewGroupShows() async {
        let fetch = FakeFetch()
        fetch.holds = false
        var asked: [String] = []
        let state = make(fetch, createWorkspace: { name in
            asked.append(name)
            fetch.workspaces = [WorkspaceSummary(id: "w-new", title: name)]
            return WorkspaceCreated(workspaceId: "w-new", title: name, created: true)
        })
        await state.reload()
        let before = fetch.calls

        await state.createWorkspace(name: "  记账  ")

        XCTAssertEqual(asked, ["记账"], "发出去的是 trim 过的名字 —— 首尾空白不是名字的一部分")
        XCTAssertEqual(state.workspaceCreation, .created)
        XCTAssertEqual(fetch.calls, before + 1, "成功之后必须重拉一次：不重拉，新组不会出现在列表里")
        XCTAssertEqual(state.workspaces.map(\.id), ["w-new"])
        XCTAssertFalse(state.isCreatingWorkspace, "动作结束后在飞标记要落")
    }

    /// 同名不是失败：结果里说的是「已有」，界面据此说不同的话。
    func testAnAlreadyExistingWorkspaceIsReportedAsSuch() async {
        let fetch = FakeFetch()
        fetch.holds = false
        let state = make(fetch, createWorkspace: { name in WorkspaceCreated(workspaceId: "w-old", title: name, created: false) })
        await state.reload()

        await state.createWorkspace(name: "已有的")

        XCTAssertEqual(state.workspaceCreation, .alreadyExists,
                       "「已有」不是失败 —— 那个工作空间已经在那儿了，界面只需说清这一点")
    }

    /// 创建失败：不重拉（组清单没变），说法落在创建结果上。
    func testAFailedWorkspaceCreationReportsAndLeavesTheListAlone() async {
        let fetch = FakeFetch()
        fetch.holds = false
        let state = make(fetch, createWorkspace: { _ in throw RpcClientError.badStatus(500) })
        await state.reload()
        let calls = fetch.calls

        await state.createWorkspace(name: "会失败的")

        XCTAssertEqual(fetch.calls, calls, "失败不重拉：组清单没变，白读一次")
        guard case .failed(let reason)? = state.workspaceCreation else {
            return XCTFail("失败该落在创建结果上，实际是 \(String(describing: state.workspaceCreation))")
        }
        XCTAssertFalse(reason.isEmpty, "失败必须有说法")
    }

    /// 打开面板时清掉上一次的结果，否则「已经有了」会一直挂在那儿。
    func testBeginningToNameClearsThePreviousOutcome() async {
        let fetch = FakeFetch()
        fetch.holds = false
        let state = make(fetch, createWorkspace: { name in WorkspaceCreated(workspaceId: "w-old", title: name, created: false) })
        await state.reload()
        await state.createWorkspace(name: "x")
        XCTAssertNotNil(state.workspaceCreation)

        state.beginNamingWorkspace()

        XCTAssertNil(state.workspaceCreation)
    }

    /// 非法名字**一个请求都不发** —— 守的是 spec「不许把非法路径送出去靠服务端兜」。
    ///
    /// 判定住在状态层（`submitWorkspaceName`）而不是视图里：视图里那句
    /// `if problem != nil { return }` 删掉不会有任何判据变红，而它守的正是这一条。
    func testAnInvalidNameNeverReachesTheNetwork() async {
        let fetch = FakeFetch()
        fetch.holds = false
        var called = 0
        let state = make(fetch, createWorkspace: { name in
            called += 1
            return WorkspaceCreated(workspaceId: "w", title: name, created: true)
        })

        for name in ["", "   ", "a/b", "a\\b", ".", ".."] {
            await state.submitWorkspaceName(name)
        }

        XCTAssertEqual(called, 0, "非法名字一个请求都不该发出去")
        XCTAssertNotNil(state.workspaceNameProblem, "拒了得给一个理由")
        XCTAssertNil(state.workspaceCreation, "没发请求就没有创建结果")
    }

    /// 合法的那一次要把上一次的红字清掉，并把 trim 过的名字发出去。
    func testAValidNameClearsTheProblemAndCreates() async {
        let fetch = FakeFetch()
        fetch.holds = false
        var asked: [String] = []
        let state = make(fetch, createWorkspace: { name in
            asked.append(name)
            return WorkspaceCreated(workspaceId: "w-new", title: name, created: true)
        })

        await state.submitWorkspaceName("a/b")
        XCTAssertNotNil(state.workspaceNameProblem)

        await state.submitWorkspaceName("  记账  ")

        XCTAssertNil(state.workspaceNameProblem, "合法的这一次要把上一次的红字清掉")
        XCTAssertEqual(asked, ["记账"])
    }

    /// 重拉撞在途：在途那次拉的是**创建之前**的快照，不能当最新用 —— 必须再拉一次。
    func testANewWorkspaceIsVisibleEvenIfAReloadWasInFlight() async {
        let fetch = FakeFetch()   // 第一次请求挂在 gate 上
        let state = make(fetch, createWorkspace: { name in
            fetch.workspaces = [WorkspaceSummary(id: "w-new", title: name)]
            return WorkspaceCreated(workspaceId: "w-new", title: name, created: true)
        })

        let pending = Task { await state.reload() }
        await settle()
        let creating = Task { await state.createWorkspace(name: "记账") }
        await settle()
        fetch.release()
        await pending.value
        await creating.value

        XCTAssertEqual(state.workspaces.map(\.id), ["w-new"],
                       "在途那次的结果早于这次创建；不重拉就等于拿旧快照当最新")
        XCTAssertEqual(fetch.calls, 2, "一次在途 + 创建之后那一次")
    }

    // MARK: - 折叠状态

    /// 切换要落盘。只在内存里变的话，重启就回到默认，而「记住」正是这一层的全部职责。
    func testTogglingAGroupPersistsTheNewState() {
        var saved: [GroupExpansion] = []
        let state = make(FakeFetch(), persisted: { saved.append($0) })

        state.toggleExpansion("w-a")

        XCTAssertTrue(state.isExpanded("w-a"), "切一下就开")
        XCTAssertEqual(saved.count, 1, "切换必须写一次盘")
        XCTAssertEqual(saved.first, state.expansion, "写出去的那一份与内存里的是同一份")
    }

    /// 没拿到组清单时不能借它做清理。
    ///
    /// `workspaces` 为空有两个来源：一个工作空间都没有，或者这一发没取到组清单。后者若被
    /// 当成前者，用户点一下折叠就把所有记录清空了 —— 那个错误不会以任何方式被看出来。
    func testTogglingWithoutAWorkspaceListKeepsEveryRecord() {
        var saved: GroupExpansion?
        let state = make(FakeFetch(),
                         expansion: GroupExpansion(expanded: ["w-old", "w-a"]),
                         persisted: { saved = $0 })

        state.toggleExpansion("w-a")     // 收起 w-a，剩 w-old

        XCTAssertEqual(saved?.expanded, Set(["w-old"]),
                       "空清单不等于「所有工作空间都没了」—— 那一刻不该清任何记录")
    }

    /// 拿到组清单之后，已经不存在的工作空间的记录在写盘时被清掉。
    func testTogglingWithAKnownListDropsRecordsOfWorkspacesThatAreGone() async {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.workspaces = [WorkspaceSummary(id: "w-a", title: "A")]
        var saved: GroupExpansion?
        let state = make(fetch,
                         expansion: GroupExpansion(expanded: ["w-gone"]),
                         persisted: { saved = $0 })
        await state.reload()

        state.toggleExpansion("w-a")

        XCTAssertEqual(saved?.expanded, Set(["w-a"]),
                       "w-gone 已经不在了；不清的话它会永远留在本机偏好里")
    }

    /// 求交的入参必须是**组 id**，不是工作空间 id。
    ///
    /// 「未分组」是一个组，但背后没有工作空间 —— 它的 id（空串）只出现在组清单里。
    /// 若求交取 `workspaces.map(\.id)`，用户点开未分组之后只要收起任意一组，它就当场被清掉，
    /// 下一次进来还是折的。这条判据因此必须让**未分组真的存在**（有会话、且没有归属）。
    func testRetainingKeepsTheUngroupedGroupWhichHasNoWorkspace() async {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.workspaces = [WorkspaceSummary(id: "w-a", title: "A")]
        fetch.rows = .success([row("loopback", updatedAt: 100)])   // 无 workspaceId ⇒ 未分组
        var saved: GroupExpansion?
        let state = make(fetch, persisted: { saved = $0 })
        await state.reload()
        XCTAssertEqual(state.sessions.map(\.workspaceId), [nil],
                       "前提：这一份数据里有一个不属于任何工作空间的会话")

        state.toggleExpansion(SessionGrouping.ungroupedKey)   // 点开未分组
        state.toggleExpansion("w-a")                          // 再收起一个工作空间组

        XCTAssertTrue(saved?.expanded.contains(SessionGrouping.ungroupedKey) == true,
                      "未分组的 id 只出现在组清单里 —— 求交取工作空间 id 会把它清掉，而界面上下次它就折回去了")
    }

    // MARK: - 删除工作空间

    /// 删完必须重拉：组消失与会话进未分组两件事都在新快照里。
    func testDeletingAWorkspaceReloadsSoTheGroupGoesAway() async {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.workspaces = [WorkspaceSummary(id: "w-a", title: "A")]
        var asked: [String] = []
        let state = make(fetch, deleteWorkspace: {
            asked.append($0)
            fetch.workspaces = []
        })
        await state.reload()
        let before = fetch.calls

        await state.deleteWorkspace("w-a")

        XCTAssertEqual(asked, ["w-a"], "删的是被点的那一个")
        XCTAssertEqual(fetch.calls, before + 1, "删完要重拉一次 —— 不重拉，组还在列表里")
        XCTAssertTrue(state.workspaces.isEmpty, "重拉回来的组清单里没有它了")
    }

    /// 失败时列表一动不动，说法落在顶部那一面。
    ///
    /// 「先本地删掉、失败再补回来」是这个仓里不该出现的形状：中间那一帧是「删了但没删掉」，
    /// 而它没有任何东西能纠正。
    func testAFailedDeletionLeavesTheListAloneAndSaysSo() async {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.workspaces = [WorkspaceSummary(id: "w-a", title: "A")]
        let state = make(fetch, deleteWorkspace: { _ in throw RpcClientError.badStatus(500) })
        await state.reload()
        let before = fetch.calls

        await state.deleteWorkspace("w-a")

        XCTAssertEqual(fetch.calls, before, "失败不重拉：组清单没变，白读一次")
        XCTAssertEqual(state.workspaces.map(\.id), ["w-a"], "组还在 —— 失败不该让界面先动")
        XCTAssertNotNil(state.failureText, "失败必须有说法（落在列表顶部那条）")
    }
}
