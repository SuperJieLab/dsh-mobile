/**
 * 会话同步的接缝判据 —— 打开帧进来之后，屏幕上那几样东西是不是真的被填上了。
 *
 * 这一层不测协议形状（那在 `SessionStreamReaderTests` 与 `MuxShapeTests`），也不测
 * 「该不该覆盖」（那在 `UsageStateTests`）：它只回答「这一帧到达之后，状态有没有跟着动」。
 * 少了这一层，两端的判据都绿而中间那一跳没人守。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionSyncTests: XCTestCase {

    /// 打开帧里的占用读数必须被采纳。
    ///
    /// 这是**没有新轮次的会话唯一的占用来源**：后续的 `usage` 帧只在读数变化时才发
    /// （网关的 `pushUsage` 拿打开时那份当基线），不产生新消息就再也不会来。丢了它，
    /// 界面永远显示 `--`，而上游投影里其实有值。
    func testOpeningOccupancyBecomesTheDisplayedUsage() {
        let sync = makeSync()
        let payload = UsagePayload(usedTokens: 148_807, contextWindow: 1_000_000)

        sync.apply(StreamReading(content: .opening(OpeningFrame(
            sessionId: "session-1",
            pageStart: 0,
            cursor: 0,
            hasOlder: false,
            events: [],
            assistantStream: nil,
            model: nil,
            occupancy: UsageSnapshot(asOfSeq: 295, usage: payload)
        ))))

        XCTAssertEqual(sync.usage, payload,
                       "打开帧带的占用被丢掉了 —— 历史会话因此永远显示 `--`")
        XCTAssertEqual(sync.usage?.percentText, "15%",
                       "顺手钉住换算：148807 / 1000000 四舍五入是 15%")
    }

    /// 之后的 `usage` 帧照旧生效，且水位更旧的被拒 —— 打开帧这条新接线不许破坏原有的判定。
    ///
    /// 两个方向都要：只测「新的能进」时，把水位判据整个删掉也是绿的。
    func testALaterUsageFrameStillWins() {
        let sync = makeSync()
        let opening = UsagePayload(usedTokens: 10, contextWindow: 100)
        sync.apply(StreamReading(content: .opening(OpeningFrame(
            sessionId: "session-1",
            pageStart: 0,
            cursor: 0,
            hasOlder: false,
            events: [],
            assistantStream: nil,
            model: nil,
            occupancy: UsageSnapshot(asOfSeq: 10, usage: opening)
        ))))
        XCTAssertEqual(sync.usage, opening)

        let newer = UsagePayload(usedTokens: 60, contextWindow: 100)
        sync.apply(StreamReading(content: .usage(UsageSnapshot(asOfSeq: 20, usage: newer))))
        XCTAssertEqual(sync.usage, newer, "水位推进了就该采用")

        let stale = UsagePayload(usedTokens: 90, contextWindow: 100)
        sync.apply(StreamReading(content: .usage(UsageSnapshot(asOfSeq: 5, usage: stale))))
        XCTAssertEqual(sync.usage, newer, "水位没推进的帧要丢 —— 乱序与重放不该让百分比跳回去")
    }

    /// 会话同步要两个真实依赖：连接（只用来取阶段）与一元客户端。
    /// 端点指向连不上的 `127.0.0.1:1`：这一组不发起请求，只喂帧。
    private func makeSync() -> SessionSync {
        let link = LongConnection(
            authorization: { "ticket" },
            renewTicket: { .unavailable },
            session: { .shared },
            baseURL: { URL(string: "http://127.0.0.1:1")! }
        )
        let credentials = CredentialStore(
            storage: .init(read: { nil }, write: { _ in }, delete: {})
        )
        let client = RpcClient(session: { .shared },
                               baseURL: { URL(string: "http://127.0.0.1:1")! },
                               credentials: credentials)
        return SessionSync(client: client, sessionId: "session-1", link: link)
    }
}
