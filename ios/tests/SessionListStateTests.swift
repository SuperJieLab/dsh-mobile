/**
 * 列表宿主的**交错**行为：一次拉取与几条变更撞在一起时，列表最后长什么样。
 *
 * 合并本身在 `SessionListMergerTests`（纯值类型）；这里测的是它之外那三件事：
 * 在途期间到达的变更（记账 + 立即生效）、两次拉取并发（单飞）、源换代次（重拉）。
 *
 * 判据都要能看见「请求发了几次」，所以取数与事件都是替身：真 socket 在这里只会把
 * 「哪一次请求落到谁的账上」混进网络的偶然。
 */
import Combine
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionListStateTests: XCTestCase {

    /// 一条会话行。只有 `updatedAt` 与标题参与本组判据。
    private func row(_ id: String, title: String? = nil, updatedAt: Double) -> SessionSummary {
        SessionSummary(
            id: id, title: title, createdAt: 1, updatedAt: updatedAt,
            running: false, blank: false, origin: nil
        )
    }

    /// 可停住、可计数的取数。第一次调用会挂在 `gate` 上直到测试放行 ——
    /// 「在途」必须是一个能被握住的时刻，不能靠 sleep 撞。
    @MainActor
    private final class FakeFetch {
        private(set) var calls = 0
        var result: Result<[SessionSummary], Error> = .success([])
        var holds = true
        private var gate: CheckedContinuation<Void, Never>?

        func fetch() async throws -> [SessionSummary] {
            calls += 1
            if holds {
                holds = false   // 只停第一次：单飞的那一条要证明第二次根本没发出去
                await withCheckedContinuation { gate = $0 }
            }
            return try result.get()
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

    private func make(_ fetch: FakeFetch) -> SessionListState {
        SessionListState { try await fetch.fetch() }
    }

    /// 让挂起的任务跑到它的第一个 await。
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - L6 单飞

    /// 两次 `reload()` 撞在一起：取数只被调一次，两次都拿到同一份结果。
    func testConcurrentReloadsShareOneRequest() async {
        let fetch = FakeFetch()
        fetch.result = .success([row("a", updatedAt: 100)])
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
        fetch.result = .success([row("a", updatedAt: 100)])
        let state = make(fetch)

        state.apply(try change(#"{"kind":"added","row":{"id":"b","updatedAt":300}}"#))
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
        fetch.result = .success([row("a", updatedAt: 100), row("z", updatedAt: 50)])
        let state = make(fetch)
        await state.reload()

        fetch.holds = true
        let pull = Task { await state.reload() }
        await settle()

        state.apply(try change(#"{"kind":"added","row":{"id":"b","updatedAt":300}}"#))
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
        fetch.result = .success([row("a", updatedAt: 100), row("b", updatedAt: 50)])
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
        fetch.result = .success([row("b", title: "拉取来的", updatedAt: 300)])
        let state = make(fetch)

        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change(#"{"kind":"added","row":{"id":"b","updatedAt":300}}"#))

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
        {"kind":"added","row":{"id":"s1","updatedAt":100,"blank":true}}
        """))
        XCTAssertTrue(state.sessions.isEmpty, "blank 行不显示")

        state.apply(try change("""
        {"kind":"added","row":{"id":"s2","updatedAt":90,"origin":"subagent"}}
        """))
        XCTAssertTrue(state.sessions.isEmpty, "子会话不显示")

        state.apply(try change(#"{"kind":"added","row":{"id":"s3","updatedAt":80}}"#))
        XCTAssertEqual(state.sessions.map(\.id), ["s3"], "普通行照常出现")
    }

    /// 在途期间到达的不可见行，重放之后也不该漏进来 —— 落地后要再筛一次。
    func testAnInvisibleRowBufferedDuringAPullDoesNotLeakOnReplay() async throws {
        let fetch = FakeFetch()
        fetch.result = .success([row("a", updatedAt: 100)])
        let state = make(fetch)

        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change("""
        {"kind":"added","row":{"id":"b","updatedAt":300,"blank":true}}
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
        let events = ConnectionEventStream()
        state.attach(events: events)

        let data = Data("""
        {"type":"item","streamId":"e1","payload":{"kind":"session-list","change":{
          "kind":"added","row":{"id":"s1","updatedAt":100}}}}
        """.utf8)
        let envelope = try JSONDecoder().decode(MuxServerEnvelope.self, from: data)
        events.handle(ConnectionEventReader.read(envelope: envelope))

        XCTAssertEqual(state.sessions.map(\.id), ["s1"], "这一帧该一路走到列表上")
    }

    /// 认不出的列表增量在消费方丢弃：坏形状不进合并器，列表不动。
    ///
    /// 丢弃口径归消费方 —— 「认不出怎么办」是读法的一部分：列表的口径是跳过这一条继续。
    func testMalformedListChangeIsDroppedAtTheConsumer() throws {
        let state = make(FakeFetch())
        let events = ConnectionEventStream()
        state.attach(events: events)

        for text in [
            #"{"type":"item","streamId":"e1","payload":{"kind":"session-list"}}"#,
            #"{"type":"item","streamId":"e1","payload":{"kind":"session-list","change":{"kind":"question"}}}"#,
        ] {
            let envelope = try JSONDecoder().decode(MuxServerEnvelope.self, from: Data(text.utf8))
            events.handle(ConnectionEventReader.read(envelope: envelope))
        }
        XCTAssertTrue(state.sessions.isEmpty, "认不出的增量一条都不该进列表")

        // 丢弃要有留痕：没有它，「列表没动」与「这两条被丢了」在屏幕上分不出来。
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/SessionList/State/SessionListState.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("dropped a session-list change this build does not know"),
                      "留痕句不在了 —— 坏增量被丢弃时现场只剩这一行")
    }

    // MARK: - L8 失败不清空

    /// 拉取失败：列表保留原样，事件带来的变化也仍在，失败面照常报。
    func testAFailedPullKeepsTheListAndTheChanges() async throws {
        let fetch = FakeFetch()
        fetch.holds = false
        fetch.result = .success([row("a", updatedAt: 100)])
        let state = make(fetch)
        await state.reload()

        // 第二发要真的停在在途：不这样的话，`apply` 落在失败之后，这条就退化成
        // 「失败不清空 + apply 会改行」，而后半是 apply 的定义。
        fetch.result = .failure(GatewayClientError.notActivated)
        fetch.holds = true
        let pull = Task { await state.reload() }
        await settle()
        state.apply(try change(#"{"kind":"activity","id":"a","updatedAt":500}"#))
        fetch.release()
        await pull.value

        XCTAssertEqual(state.sessions.map(\.id), ["a"], "失败不清空")
        XCTAssertEqual(state.sessions[0].updatedAt, 500, "失败之后事件仍然生效")
        XCTAssertEqual(state.outcome, .waitingForMesh, "失败面如实")
    }

    // MARK: - L7 换代次重拉

    /// 事件流每报到一次（含重连拿到相同代次），就重拉一次 —— 这条流不重放，
    /// 「两次报到之间的事件可能丢了」在客户端唯一可观察的形式就是它。
    func testEveryGenerationReportPullAgain() async throws {
        let fetch = FakeFetch()
        fetch.holds = false
        let state = make(fetch)
        let events = ConnectionEventStream()
        state.attach(events: events)

        events.handle(ConnectionEventReading(content: .ready(generation: 3)))
        await settle()
        XCTAssertEqual(fetch.calls, 1, "第一次 ready")

        events.handle(ConnectionEventReading(content: .ready(generation: 3)))
        await settle()
        XCTAssertEqual(fetch.calls, 2, "重连拿到相同代次也是新的开始")

        events.handle(ConnectionEventReading(content: .ready(generation: nil)))
        await settle()
        XCTAssertEqual(fetch.calls, 3, "源失效也要重拉：那些事件再也补不回来")
    }
}
