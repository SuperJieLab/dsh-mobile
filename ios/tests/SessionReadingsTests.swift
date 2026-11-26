/**
 * 读数与翻页单元自己的判据 —— 以 `SessionReadings` 为被测对象，不经过协调者的转发面。
 *
 * 守的是「点一次加载更早，窗口与屏幕上的读数十么时候跟着动、不跟着动的那几种情况怎么说」。
 * 视图那一列的合并另有 `SessionSyncTests`，这里只喂窗口与应答。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionReadingsTests: XCTestCase {

    // MARK: - 夹具

    private func record(_ seq: Int) -> SessionRecord {
        SessionRecord(type: "user/message", event: SessionEvent(
            type: "user/message", seq: seq, time: Double(seq), data: .object([
                "id": .string("m-\(seq)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([.object(["type": .string("text"), "text": .string("本地-\(seq)")])]),
            ])
        ))
    }

    /// 一屏已有的窗口。`realign` 在本地为空时与「打开」同一件事。
    private func window(seqs: [Int], cursor: Int, hasMore: Bool) -> SessionWindow {
        SessionWindow(records: seqs.map(record), cursor: cursor, hasMore: hasMore)
    }

    private func pageBody(records seqs: [Int], cursor: Int, hasMore: Bool) -> String {
        let items = seqs.map { seq in
            #"{"type":"user/message","event":{"type":"user/message","seq":\#(seq),"time":1,"data":{"id":"m-\#(seq)","source":{"kind":"user"},"content":[{"type":"text","text":"更早-\#(seq)"}]}}}"#
        }
        let list = "[" + items.joined(separator: ",") + "]"
        return #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"records":\#(list),"cursor":\#(cursor),"hasMore":\#(hasMore)}}}"#
    }

    private func makeClient() -> RpcClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = CredentialStore(
            storage: .init(read: { nil }, write: { _ in }, delete: {})
        )
        return RpcClient(session: { session },
                         baseURL: { URL(string: "http://127.0.0.1:9")! },
                         credentials: credentials)
    }

    /// 一套最小装配：窗口事实 + 状态行 + 单元；刷新那条出线接到「重算两个计数」——
    /// 协调者接的是 `refreshView`（多一步物化），计数那一半等价。
    private func make(_ window: SessionWindow) -> (SessionInput, SessionStatus, SessionReadings) {
        ScriptedURLProtocol.reset(replies: [:])
        let input = SessionInput(sessionId: "s-1", control: nil)
        _ = input.realign(with: window)
        let status = SessionStatus()
        let readings = SessionReadings(client: makeClient(), sessionId: "s-1",
                                       input: input, statusBox: status)
        readings.onRefreshNeeded = { [weak readings] in readings?.refreshCounts() }
        readings.refreshCounts()
        return (input, status, readings)
    }

    private func pageCalls() -> Int {
        ScriptedURLProtocol.snapshot().filter { $0.op == "session/page" }.count
    }

    // MARK: - 一页之后，计数与窗口同一拍

    /// 一页前插之后，两个计数要跟窗口一起动 —— 与快照同一拍，否则视图会读到
    /// 「新快照配旧条数」，而这类错只在切屏那一帧可见。
    func testAPagesUpdatesTheCountsInTheSameBeatAsTheWindow() async {
        let (input, _, readings) = make(window(seqs: [5, 6], cursor: 6, hasMore: true))
        XCTAssertEqual(readings.eventCount, 2, "先确认起点：窗口里两条")
        XCTAssertTrue(readings.hasMore)

        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(status: 200, body: pageBody(records: [4], cursor: 6, hasMore: false)),
        ])

        await readings.loadOlder(visibleNodeCount: { readings.eventCount })

        XCTAssertEqual(pageCalls(), 1, "这一页带来了可显示的行，不该再往前拉")
        XCTAssertEqual(input.windowStart, 4, "窗口起点该跟着那一页前移")
        XCTAssertEqual(readings.eventCount, 3, "计数没跟窗口一起动")
        XCTAssertFalse(readings.hasMore, "服务端说到头了，界面那个入口该收起来")
        XCTAssertFalse(readings.isPagingOlder, "收场要把指示灯熄掉")
    }

    // MARK: - 挤牙膏

    /// 每页都合并 0 条：最多问三次就停。
    ///
    /// 起点必须是 0（窗口里有一条 `seq: 0`）：空页只在 `windowStart - 1 == -1` 时被判成
    /// 接上，否则第一页就判缺口。
    func testThreePagesIsTheCeilingWhenEveryPageIsEmpty() async {
        let (_, _, readings) = make(window(seqs: [0], cursor: 0, hasMore: true))

        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(status: 200, body: pageBody(records: [], cursor: 0, hasMore: true)),
        ])

        await readings.loadOlder(visibleNodeCount: { 1 })

        XCTAssertEqual(pageCalls(), 3, "挤牙膏时该停在第三页 —— 多拉是闷拉，少拉是半途而废")
        XCTAssertFalse(readings.isPagingOlder)
    }

    // MARK: - 缺口

    /// 这一页接不上本地起点：停手、不重试、不请求重建，只在告知里记一笔。
    func testAGapStopsWithoutRetryingOrRebuilding() async {
        let (_, _, readings) = make(window(seqs: [5, 6], cursor: 6, hasMore: true))
        var rebuildAsked = false
        readings.onRebuildNeeded = { rebuildAsked = true }

        // 这一页的末尾落在 2，本地起点是 5 —— 中间缺了 3、4。
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(status: 200, body: pageBody(records: [2], cursor: 6, hasMore: true)),
        ])

        await readings.loadOlder(visibleNodeCount: { readings.eventCount })

        XCTAssertEqual(pageCalls(), 1, "缺口之后不该继续往前拉")
        XCTAssertFalse(rebuildAsked, "缺口时本地内容仍然是真的，不该清屏重来")
        XCTAssertEqual(readings.notice?.kind, .unresolved, "缺口要留下告知 —— 否则界面静止却看起来正常")
        XCTAssertEqual(readings.notice?.reason, .gap)
        XCTAssertFalse(readings.isPagingOlder)
    }

    // MARK: - 失败的两种说法

    /// 拒帧与传输失败要分开说：前者是服务端说「这次不行」，后者是没连上。
    ///
    /// 状态是 `SessionStatus.Value`（不是 `Equatable`，里面挂着 `any Error`），所以用模式匹配断言。
    func testFailuresHaveTwoVoices() async {
        let (_, rejectedStatus, rejected) = make(window(seqs: [5, 6], cursor: 6, hasMore: true))
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"not-found","message":"x","details":{}}}}"#
            ),
        ])
        await rejected.loadOlder(visibleNodeCount: { 2 })

        guard case .failed(let rejectedStep, let rejectedCause) = rejectedStatus.value else {
            return XCTFail("拒帧之后状态不是失败")
        }
        guard case .paging = rejectedStep else { return XCTFail("失败要落在分页这一步") }
        guard case .refusal(let code) = rejectedCause else { return XCTFail("拒帧说成了传输失败") }
        XCTAssertEqual(code, "not-found")

        let (_, brokenStatus, broken) = make(window(seqs: [5, 6], cursor: 6, hasMore: true))
        ScriptedURLProtocol.reset(replies: [:])
        ScriptedURLProtocol.transportFailure = URLError(.notConnectedToInternet)
        await broken.loadOlder(visibleNodeCount: { 2 })

        guard case .failed(let brokenStep, let brokenCause) = brokenStatus.value else {
            return XCTFail("传输失败之后状态不是失败")
        }
        guard case .paging = brokenStep else { return XCTFail("失败要落在分页这一步") }
        guard case .transport = brokenCause else { return XCTFail("没连上不该说成「服务端拒绝了」") }
    }

    // MARK: - 占用水位

    /// 两条来源两套规则：快照按水位（严格更高才采用），control 接管之后直接覆盖、快照当历史。
    ///
    /// 这正是 `UsageState` 文件头写的那件事 —— 两条水位不同轴，拿一个去比另一个必然出错。
    func testUsageTakesSnapshotsUntilControlTakesOver() {
        let (_, _, readings) = make(window(seqs: [5, 6], cursor: 6, hasMore: false))
        func payload(_ tokens: Int) -> UsagePayload {
            UsagePayload(usedTokens: tokens, contextWindow: 100)
        }

        readings.applyUsage(UsageSnapshot(asOfSeq: 20, usage: payload(50)))
        XCTAssertEqual(readings.usage?.usedTokens, 50)
        XCTAssertNotNil(readings.lastFrameAt, "打开帧的投影块也算「数据到了」")

        readings.applyUsage(UsageSnapshot(asOfSeq: 20, usage: payload(90)))
        XCTAssertEqual(readings.usage?.usedTokens, 50, "水位没推进的要丢 —— 乱序与重放不该让百分比跳回去")

        readings.applyUsage(UsageSnapshot(asOfSeq: 21, usage: payload(60)))
        XCTAssertEqual(readings.usage?.usedTokens, 60, "水位推进了就该采用")

        readings.noteUsage(payload(70))
        XCTAssertEqual(readings.usage?.usedTokens, 70, "control 是权威，直接覆盖")

        readings.applyUsage(UsageSnapshot(asOfSeq: 99, usage: payload(80)))
        XCTAssertEqual(readings.usage?.usedTokens, 70, "接管之后快照再高也不覆盖 —— 两条水位不同轴")
    }

    // MARK: - 告知

    /// 告知两种各置位一次，且**置位之后不清除**（中间那段确实是缺的，后来接得上也不改这个事实）。
    func testANoticeIsRaisedForBothReasonsAndNeverCleared() {
        let (_, _, readings) = make(window(seqs: [5, 6], cursor: 6, hasMore: false))

        readings.noteVerdict(.resetRequired(.gap))
        XCTAssertEqual(readings.notice?.kind, .unresolved, "有洞时本地那段仍然是真的 —— 说「没接上」，不说「已重置」")
        XCTAssertEqual(readings.notice?.reason, .gap)

        readings.noteVerdict(.resetRequired(.waterMarkWentBack))
        XCTAssertEqual(readings.notice?.kind, .reset, "位置被否定才说「已重置」")
        XCTAssertEqual(readings.notice?.reason, .waterMarkWentBack)

        // 接得上、别的失败都不该把它抹掉。
        readings.noteVerdict(.caughtUp)
        readings.noteVerdict(.merged(added: 1))
        readings.noteVerdict(.failed)
        readings.noteVerdict(.refused(code: "x"))
        XCTAssertEqual(readings.notice?.kind, .reset, "告知被后来的正常帧清掉了")
    }
}
