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

        sync.apply(StreamReading(content: .opening(SnapshotFrame(
            header: SessionWireHeader(version: 1, id: "session-1", createdAt: 0, cwd: nil,
                                      parentSession: nil, isSeeded: false, origin: nil,
                                      delegationDepth: nil, agentPreset: nil),
            cursor: 0,
            records: [],
            hasMore: false,
            projections: ProjectionBlock(asOfSeq: 295, values: .object([
                "contextPressure": .object([
                    "projectedTokens": .number(148_807),
                    "contextWindow": .number(1_000_000),
                ]),
            ])),
            assistantStream: nil
        ))))

        XCTAssertEqual(sync.usage, payload,
                       "打开帧带的占用被丢掉了 —— 历史会话因此永远显示 `--`")
        XCTAssertEqual(sync.usage?.percentText, "15%",
                       "顺手钉住换算：148807 / 1000000 四舍五入是 15%")
    }

    /// 判据 10：当前模型由 `modelSelection` **投影**驱动 —— 切了模型它跟着变，
    /// 而打开帧那一份永远停在打开那一刻（第 2 期起那一份已经没有了）。
    ///
    /// 走的是真解码：控制帧的文本进 `ControlStream.handle`，与生产同一条路。
    func testTheModelSelectionProjectionDrivesTheDisplayedModel() throws {
        let control = ControlStream()
        let sync = makeSync(control: control)

        func controlItem(_ value: String) throws -> InboundFrame {
            try XCTUnwrap(InboundFrame.decode(Data(#"{"type":"item","streamId":"c-1","value":\#(value)}"#.utf8)))
        }

        // 基线：control 打开时给整份投影表。
        _ = control.handle(try controlItem(#"""
        {"type":"baseline","value":{"projections":{"session-1":{"asOfSeq":7,"values":{
          "modelSelection":{"lastUsed":{"provider":"deepseek","model":"chat"},
                            "next":{"provider":"deepseek","model":"reasoner","reasoningEffort":"high"}}}}}}}
        """#))
        XCTAssertEqual(sync.displayedModel?.model, "reasoner",
                       "投影里的 next 就是功能条上那个模型（下一轮将用的那个）")

        // 增量：用户切回上一轮那个（`next` 为 null）—— 投影变了，显示跟着变。
        _ = control.handle(try controlItem(#"""
        {"type":"projection","sessionId":"session-1","seq":9,"changes":[
          {"key":"modelSelection","val":{"lastUsed":{"provider":"deepseek","model":"chat"},"next":null}}]}
        """#))
        XCTAssertEqual(sync.displayedModel?.model, "chat",
                       "投影一变显示就变 —— 打开帧那一份做不到这件事，所以它不能再有")

        // 别的会话的投影不该动这一屏。
        _ = control.handle(try controlItem(#"""
        {"type":"projection","sessionId":"session-2","seq":10,"changes":[
          {"key":"modelSelection","val":{"lastUsed":{"provider":"p","model":"other"},"next":null}}]}
        """#))
        XCTAssertEqual(sync.displayedModel?.model, "chat", "串会话的投影被丢掉")
    }

    /// 之后的 `usage` 帧照旧生效，且水位更旧的被拒 —— 打开帧这条新接线不许破坏原有的判定。
    ///
    /// 两个方向都要：只测「新的能进」时，把水位判据整个删掉也是绿的。
    func testALaterUsageFrameStillWins() {
        let sync = makeSync()
        let opening = UsagePayload(usedTokens: 10, contextWindow: 100)
        sync.apply(StreamReading(content: .opening(SnapshotFrame(
            header: SessionWireHeader(version: 1, id: "session-1", createdAt: 0, cwd: nil,
                                      parentSession: nil, isSeeded: false, origin: nil,
                                      delegationDepth: nil, agentPreset: nil),
            cursor: 0,
            records: [],
            hasMore: false,
            projections: ProjectionBlock(asOfSeq: 10, values: .object([
                "contextPressure": .object([
                    "projectedTokens": .number(50),
                    "contextWindow": .number(100),
                ]),
            ])),
            assistantStream: nil
        ))))
        // 打开帧的占用**取自 `projections`**（第 1 期把 usage 收进投影）—— 窗口里那格
        // `opening` 只是基线之前的值，不该赢过同帧带来的投影。
        XCTAssertEqual(sync.usage, UsagePayload(usedTokens: 50, contextWindow: 100))

        // 水位推进了就该采用；没推进的（乱序或重放）要丢 —— 与 `UsageState` 同一条规则。
        sync.applyOpeningProjections(ProjectionBlock(asOfSeq: 20, values: .object([
            "contextPressure": .object([
                "projectedTokens": .number(60),
                "contextWindow": .number(100),
            ]),
        ])))
        XCTAssertEqual(sync.usage?.usedTokens, 60, "水位推进了就该采用")

        sync.applyOpeningProjections(ProjectionBlock(asOfSeq: 5, values: .object([
            "contextPressure": .object([
                "projectedTokens": .number(90),
                "contextWindow": .number(100),
            ]),
        ])))
        XCTAssertEqual(sync.usage?.usedTokens, 60, "水位没推进的要丢 —— 乱序与重放不该让百分比跳回去")
    }

    /// 会话同步要两个真实依赖：连接（只用来取阶段）与一元客户端。
    /// 端点指向连不上的 `127.0.0.1:1`：这一组不发起请求，只喂帧。
    /// 判据 7：发出去的那一行先上屏，持久事件按 `source.rpcId` 认领它。
    ///
    /// 两条路各自都绿、中间那一跳没人守，就会同时出现「两条一样的消息」或
    /// 「屏幕上什么都没有」—— 而这两种都不报错。
    func testAnAcceptedPromptShowsAtOnceAndRetiresOnItsDurableMessage() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/prompt": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"accepted":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.apply(StreamReading(content: .opening(snapshot(cursor: 4, records: []))))

        let accepted = await sync.deliver(.prompt("你好"), mode: .queue)
        XCTAssertTrue(accepted, "受理了")
        let pending = try XCTUnwrap(sync.pendingPrompts.first, "受理之后那条乐观行该在")
        XCTAssertEqual(sync.nodes.last?.data, .message(MessageNodeData(text: "你好", time: pending.time)),
                       "发出去的字立刻上屏 —— 不必等宿主落成持久事件")

        // 宿主把它落成持久事件，带着同一个 rpcId。
        sync.apply(StreamReading(content: .event(SessionEvent(
            type: "user/message", seq: 5, time: 2,
            data: .object([
                "id": .string("m-1"),
                "source": .object(["kind": .string("user"), "rpcId": .string(pending.requestId)]),
                "content": .array([.object(["type": .string("text"), "text": .string("你好")])]),
            ])
        ))))
        XCTAssertTrue(sync.pendingPrompts.isEmpty, "持久事件一到，乐观行就该交接")
        try await Task.sleep(for: .milliseconds(60))
        let texts = sync.nodes.compactMap { node -> String? in
            if case .message(let message) = node.data { return message.text }
            return nil
        }
        XCTAssertEqual(texts.filter { $0 == "你好" }.count, 1, "同一句话只该有一行")
    }

    /// 发送失败即撤：那一行不能留在屏幕上假装发出去了。
    func testAFailedPromptTakesItsOptimisticRowAway() async {
        ScriptedURLProtocol.reset(replies: [
            "session/prompt": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"internal-error","message":"no","details":{}}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.apply(StreamReading(content: .opening(snapshot(cursor: 0, records: []))))

        let accepted = await sync.deliver(.prompt("发不出去"), mode: .queue)
        XCTAssertFalse(accepted)
        XCTAssertTrue(sync.pendingPrompts.isEmpty, "没送到就不该留一行")
    }

    /// 一份最小的打开帧夹具 —— 只给判据要用的四格。
    private func snapshot(cursor: Int, records: [SessionRecord]) -> SnapshotFrame {
        SnapshotFrame(
            header: SessionWireHeader(version: 1, id: "session-1", createdAt: 0, cwd: nil,
                                      parentSession: nil, isSeeded: false, origin: nil,
                                      delegationDepth: nil, agentPreset: nil),
            cursor: cursor,
            records: records,
            hasMore: false,
            projections: ProjectionBlock(asOfSeq: cursor, values: .object([:])),
            assistantStream: nil
        )
    }

    /// 走真传输的 `SessionSync`（脚本化 URLProtocol）——「受理」这条分支需要真的回包。
    private func makeScriptedSync() -> SessionSync {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = CredentialStore(
            storage: .init(read: { nil }, write: { _ in }, delete: {})
        )
        let client = RpcClient(session: { session },
                               baseURL: { URL(string: "http://127.0.0.1:9")! },
                               credentials: credentials)
        let link = LongConnection(
            authorization: { "ticket" },
            renewTicket: { .unavailable },
            session: { session },
            baseURL: { URL(string: "http://127.0.0.1:9")! }
        )
        return SessionSync(client: client, sessionId: "session-1", link: link)
    }

    private func makeSync(control: ControlStream? = nil) -> SessionSync {
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
        return SessionSync(client: client, sessionId: "session-1", link: link, control: control)
    }
}
