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

        sync.projection.apply(StreamReading(content: .opening(SnapshotFrame(
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

    /// 当前模型由 `modelSelection` **投影**驱动 —— 切了模型它跟着变，
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
        sync.projection.apply(StreamReading(content: .opening(SnapshotFrame(
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

    /// 发出去的那一行先上屏，持久事件按 `source.rpcId` 认领它。
    ///
    /// 两条路各自都绿、中间那一跳没人守，就会同时出现「两条一样的消息」或
    /// 「屏幕上什么都没有」—— 而这两种都不报错。走真传输（脚本化 URLProtocol），
    /// 因为「受理」这条分支需要真的回包。
    func testAnAcceptedPromptShowsAtOnceAndRetiresOnItsDurableMessage() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/prompt": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"accepted":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 4, records: []))))

        let accepted = await sync.deliver(.prompt("你好"), mode: .queue)
        XCTAssertTrue(accepted, "受理了")
        let pending = try XCTUnwrap(sync.optimist.entries.first, "受理之后那条乐观行该在")
        XCTAssertEqual(sync.nodes.last?.data, .message(MessageNodeData(text: "你好", time: pending.time)),
                       "发出去的字立刻上屏 —— 不必等宿主落成持久事件")

        // 宿主把它落成持久事件，带着同一个 rpcId。
        sync.projection.apply(StreamReading(content: .event(SessionEvent(
            type: "user/message", seq: 5, time: 2,
            data: .object([
                "id": .string("m-1"),
                "source": .object(["kind": .string("user"), "rpcId": .string(pending.requestId)]),
                "content": .array([.object(["type": .string("text"), "text": .string("你好")])]),
            ])
        ))))
        // 交接要等新快照建好（一个渲染帧的合并窗口）—— 这一拍里那一行**不能消失**。
        XCTAssertEqual(texts(in: sync), ["你好"], "交接的空窗里那一行不能消失（撤早了会闪一下）")

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(sync.optimist.entries.isEmpty, "持久行上屏之后，乐观行才撤")
        XCTAssertEqual(texts(in: sync), ["你好"], "同一句话只该有一行")
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
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 0, records: []))))

        let accepted = await sync.deliver(.prompt("发不出去"), mode: .queue)
        XCTAssertFalse(accepted)
        XCTAssertTrue(sync.optimist.entries.isEmpty, "没送到就不该留一行")
        XCTAssertEqual(texts(in: sync), [], "屏幕上也不能留着 —— 那会假装发出去了")
    }

    // MARK: - 翻页、草稿基线、开关（F5 第 1 期 T1：搬状态之前先把现状钉住）

    /// 窗口说没有更早的了：一次请求都不发。
    func testLoadOlderStopsWhenTheWindowHasNoMore() async throws {
        ScriptedURLProtocol.reset(replies: [:])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 4, records: []))))

        await sync.loadOlder()

        XCTAssertEqual(pageCalls(), 0, "`hasMore` 为假时不该发请求")
    }

    /// 这一页接上了本地起点，且带来了可显示的行：只发一次请求就收工。
    func testLoadOlderStopsOnceAPageBringsSomethingVisible() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"records":[{"type":"user/message","event":{"type":"user/message","seq":10,"time":1,"data":{"id":"m-10","source":{"kind":"user"},"content":[{"type":"text","text":"更早的一句"}]}}}],"cursor":10,"hasMore":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 10, records: [], hasMore: true))))
        let before = sync.nodes.count

        await sync.loadOlder()

        XCTAssertEqual(pageCalls(), 1, "已经有新行了，不该再往前拉")
        XCTAssertEqual(sync.nodes.count, before + 1, "那一页的行要真的上屏")
    }

    /// 服务端挤牙膏（每页都合并 0 条）：最多问三次就停。
    ///
    /// 夹具的关键：`SessionWindow.start` 对空窗口取 `cursor + 1`，所以打开帧必须**带一条
    /// `seq: 0` 的记录**，窗口起点才是 0；而空页只在「起点 - 1 == -1」时被判成接上（`endsAt`
    /// 对空页的判据）。少了那条记录，第一页就判缺口、直接 return，一次都到不了三。
    func testLoadOlderStopsAtThreePagesWhenEveryPageIsEmpty() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"records":[],"cursor":0,"hasMore":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 0, records: [userRecord(0)], hasMore: true)
        )))

        await sync.loadOlder()

        XCTAssertEqual(pageCalls(), 3, "挤牙膏时该停在第三页 —— 多拉是闷拉，少拉是半途而废")
        XCTAssertFalse(sync.isPagingOlder, "收场要把指示灯熄掉")
    }

    /// 翻页失败之后，指示灯也要熄 —— 否则顶部一直转圈，用户以为还在等。
    func testPagingFailureTurnsTheIndicatorOff() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(status: 500, body: "boom"),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 10, records: [], hasMore: true))))

        await sync.loadOlder()

        XCTAssertFalse(sync.isPagingOlder, "失败那一支没把指示灯熄掉")
    }

    /// 三条「数据到了」的路都要推进时间戳：control 的一条投影、打开帧的投影块、一条数据帧。
    ///
    /// 各自钉各自的入口 —— 打开帧那条**直接调** `applyOpeningProjections`：经 `projection.apply`
    /// 的话投影自己也会盖一次章，把「单元漏盖」遮住；control 那条直接触发装配好的闭包，
    /// 不必造真的 `ControlStream`（它无条件装配）。
    func testEveryDataPathAdvancesTheLastFrameTime() {
        let values: JSONValue = .object(["contextPressure": .object([
            "projectedTokens": .number(10),
            "contextWindow": .number(100),
        ])])

        let viaControl = makeSync()
        XCTAssertNil(viaControl.lastFrameAt, "先确认起点是空的")
        viaControl.input.onControlValues?(values)
        XCTAssertNotNil(viaControl.lastFrameAt, "control 的一条投影没推进时间戳")
        XCTAssertEqual(viaControl.usage?.usedTokens, 10, "顺带确认那条路真的走到了占用判定")

        let viaOpening = makeSync()
        viaOpening.applyOpeningProjections(ProjectionBlock(asOfSeq: 5, values: values))
        XCTAssertNotNil(viaOpening.lastFrameAt, "打开帧的投影块没推进时间戳")

        let viaEvent = makeSync()
        viaEvent.projection.apply(StreamReading(content: .event(userRecord(0).event)))
        XCTAssertNotNil(viaEvent.lastFrameAt, "数据帧没推进时间戳")
    }

    /// 这一页接不上本地起点（缺口）：停手，不重试，只在告知里记一笔。
    ///
    /// 缺口时本地内容仍然是真的、只是旧 —— 所以既不重试也不清屏。
    /// **本地得真有内容**：打开帧给空窗口时，「本地一条不动」是恒真的空断言。
    func testLoadOlderStopsOnAGapAndKeepsTheLocalContent() async throws {
        func local(_ seq: Int) -> SessionRecord {
            SessionRecord(type: "user/message", event: SessionEvent(
                type: "user/message", seq: seq, time: Double(seq), data: .object([
                    "id": .string("m-\(seq)"),
                    "source": .object(["kind": .string("user")]),
                    "content": .array([.object(["type": .string("text"), "text": .string("本地-\(seq)")])]),
                ])
            ))
        }
        // 本地窗口是 6..<10，这一页的末尾落在 3 —— 与本地起点差两条，判缺口。
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"records":[{"type":"user/message","event":{"type":"user/message","seq":3,"time":1,"data":{"id":"m-3","source":{"kind":"user"},"content":[{"type":"text","text":"接不上的"}]}}}],"cursor":10,"hasMore":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 9, records: (6..<10).map(local), hasMore: true)
        )))
        XCTAssertEqual(texts(in: sync).count, 4, "先确认本地真的有内容")

        await sync.loadOlder()

        XCTAssertEqual(pageCalls(), 1, "缺口之后不该继续往前拉")
        XCTAssertNotNil(sync.notice, "缺口要留下告知 —— 否则界面静止却看起来正常")
        XCTAssertEqual(texts(in: sync), ["本地-6", "本地-7", "本地-8", "本地-9"],
                       "缺口时本地一条不动，也不把那一页塞进来")
    }

    /// 翻页失败落在「分页」这一步，而不是笼统失败。
    func testLoadOlderFailureShowsPagingFailure() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(status: 500, body: "boom"),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 10, records: [], hasMore: true))))

        await sync.loadOlder()

        guard case .failed(let step, _) = sync.status else {
            return XCTFail("状态不是失败：\(sync.status)")
        }
        guard case .paging = step else {
            return XCTFail("失败没落在分页这一步：\(step)")
        }
    }

    /// 打开帧带一个进行中的 attempt：草稿行按基线内容恢复。
    func testAnOpeningWithALiveAttemptRestoresTheDraft() {
        let sync = makeSync()

        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 4, records: [], assistantStream: liveBaseline())
        )))

        XCTAssertTrue(assistantTexts(in: sync).contains("半句话"),
                      "基线里的草稿没恢复 —— 重开流那一刻屏幕上会空一段")
    }

    /// 下一次打开不带 attempt：上一段草稿必须清掉，否则与新基线拼成两段重复文本。
    func testASecondOpeningWithoutALiveAttemptClearsTheDraft() {
        let sync = makeSync()
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 4, records: [], assistantStream: liveBaseline())
        )))
        XCTAssertTrue(assistantTexts(in: sync).contains("半句话"), "先确认草稿真的在")

        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 6, records: []))))

        let draft = sync.snapshot.nodes.first { node in
            if case .assistant(let assistant) = node.data { return assistant.text == "半句话" }
            return false
        }
        guard let draft else { return }   // 整条消失也算退役，比留着更好
        XCTAssertNotEqual(draft.visibility, .visible,
                          "旧草稿还在屏上 —— 它会和新基线拼成两段")
    }

    /// 离屏要退订、回屏要补订：监听表不随进出增长。
    func testStoppingFollowingUnsubscribesTheControlStream() {
        let control = ControlStream()
        let sync = makeSync(control: control)

        sync.startFollowing()
        XCTAssertEqual(control.updateListeners.count, 1, "开屏就该订上")

        sync.stopFollowing()
        XCTAssertEqual(control.updateListeners.count, 0,
                       "离屏没退订 —— 监听表持弱引用，泄漏不报错，只让每次投影多跑一次空转")

        sync.startFollowing()
        XCTAssertEqual(control.updateListeners.count, 1, "回屏要补订")
    }

    /// 上一代被扣下的定稿，在下一帧打开之后必须进引擎。
    ///
    /// 失效形态：那一条留在暂存里当作废处理（只清不排回），而喂食那一步正是按暂存过滤的 ——
    /// 于是窗口里有它、引擎里没有它，屏幕永久少一行，且没有任何报错。
    func testAHeldSettlementReachesTheEngineOnceANewStreamStarts() {
        func durable(_ seq: Int) -> SessionRecord {
            SessionRecord(type: "assistant/message", event: SessionEvent(
                type: "assistant/message", seq: seq, time: Double(seq), data: .object([
                    "turn": .number(1),
                    "step": .number(1),
                    "message": .object([
                        "id": .string("m-\(seq)"),
                        "content": .array([.object(["type": .string("text"), "text": .string("正式正文")])]),
                    ]),
                ])
            ))
        }

        let sync = makeSync()
        let context = [
            SessionRecord(type: "turn/start", event: SessionEvent(
                type: "turn/start", seq: 0, time: 0, data: .object(["turn": .number(1)])
            )),
            SessionRecord(type: "step/start", event: SessionEvent(
                type: "step/start", seq: 1, time: 1, data: .object([
                    "turn": .number(1), "step": .number(1),
                ])
            )),
        ]
        // 打开一屏并带一个活草稿 —— 只有草稿开着，定稿才可能被扣下。
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 1, records: context, assistantStream: liveBaseline())
        )))
        XCTAssertTrue(assistantTexts(in: sync).contains("半句话"), "先确认草稿真的在")

        sync.projection.apply(StreamReading(content: .event(durable(2).event)))
        XCTAssertFalse(assistantTexts(in: sync).contains("正式正文"),
                       "草稿还开着，定稿要先扣着 —— 它可能是比草稿先到的那一份")

        // 新的一条流开始，窗口里带着那条定稿：它必须出现在引擎里。
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 2, records: context + [durable(2)])
        )))

        XCTAssertTrue(assistantTexts(in: sync).contains("正式正文"),
                      "扣下的定稿没有回到引擎 —— 这一轮会永久少一行")
    }

    /// 整段重建：水位回退之后镜像与引擎一起清，新窗口用的是新身份。
    ///
    /// 三步缺一不可。只看第 ② 步证明不了「重建用的是新窗口」，只看第 ③ 步证明不了清空 ——
    /// 而「清了镜像、没清引擎」的表现是旧身份还在，新窗口的事件被判成前插接到旧内容上。
    ///
    /// 另有一处易错：跳号（`.gap`）**不**触发重建（`invalidatesLocalContent` 为假），
    /// 所以这里摔的是水位回退，不是缺一条。
    func testARewoundWatermarkRebuildsTheWholeWindow() {
        func message(_ seq: Int, _ text: String) -> SessionRecord {
            SessionRecord(type: "user/message", event: SessionEvent(
                type: "user/message", seq: seq, time: Double(seq), data: .object([
                    "id": .string("m-\(seq)"),
                    "source": .object(["kind": .string("user")]),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                ])
            ))
        }

        let sync = makeSync()
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 9, records: (0..<10).map { message($0, "旧-\($0)") })
        )))
        XCTAssertEqual(sync.eventCount, 10, "先确认整窗真的进去了")

        // 水位回退：`realign` 提前返回、不采用新窗口，随后 `resetMirror` 把镜像与引擎一起清。
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 7, records: (0..<8).map { message($0, "旧-\($0)") })
        )))
        XCTAssertEqual(sync.eventCount, 0, "水位回退之后镜像必须清空")
        XCTAssertTrue(sync.nodes.isEmpty,
                      "镜像清了、引擎没清 —— 屏幕还留着上一段窗口的内容")

        // 这条流随后送一份正常的新窗口：必须照新窗口重建，不把旧身份接上。
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 7, records: (0..<8).map { message($0, "新-\($0)") })
        )))
        XCTAssertEqual(sync.eventCount, 8)
        XCTAssertEqual(sync.nodes.count, 8, "节点数不是 8 —— 旧窗口的内容还挂在引擎里")
        XCTAssertEqual(texts(in: sync).filter { $0.hasPrefix("旧-") }, [],
                       "旧窗口那两条还在屏上 —— 重建把两段不同的窗口拼成了一个")
    }

    /// 这一屏的状态随协调者一起释放。
    ///
    /// 两个单元互相引用是这类拆法最容易长出来的东西：输入单元持有造流闭包，闭包若强持投影，
    /// 而投影又强持输入单元 —— 那一环没人看得见，症状是离开详情页之后整条引擎与快照还在内存里。
    func testTheScreenStateDiesWithTheCoordinator() {
        weak var weakInput: SessionInput?
        weak var weakProjection: SessionProjection?
        weak var weakOptimist: SessionOptimist?
        autoreleasepool {
            let sync = makeSync()
            weakInput = sync.input
            weakProjection = sync.projection
            weakOptimist = sync.optimist
        }
        XCTAssertNil(weakInput, "输入单元活过了协调者 —— 它与投影之间有一环")
        XCTAssertNil(weakProjection, "投影活过了协调者 —— 同上")
        XCTAssertNil(weakOptimist, "乐观行单元活过了协调者 —— 它持有的闭包强持了谁")
    }

    /// 打开帧同时带来持久记录与草稿基线：两样都要在。
    ///
    /// 顺序是唯一让它成立的东西：持久窗口先喂进引擎，基线才追加得进去。反过来的话，
    /// 紧接着的整段重建会在基线刚放进去之后把引擎清一遍 —— 屏幕上只剩持久的那几条。
    func testAnOpeningWithBothRecordsAndADraftShowsBoth() {
        func message(_ seq: Int) -> SessionRecord {
            SessionRecord(type: "user/message", event: SessionEvent(
                type: "user/message", seq: seq, time: Double(seq), data: .object([
                    "id": .string("m-\(seq)"),
                    "source": .object(["kind": .string("user")]),
                    "content": .array([.object(["type": .string("text"), "text": .string("持久-\(seq)")])]),
                ])
            ))
        }

        let sync = makeSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(
            cursor: 1, records: [message(0), message(1)], assistantStream: liveBaseline()
        ))))

        XCTAssertEqual(texts(in: sync), ["持久-0", "持久-1"], "持久那一列没上屏")
        XCTAssertTrue(assistantTexts(in: sync).contains("半句话"),
                      "草稿被持久窗口那次重建抹掉了 —— 基线必须放在喂完窗口之后")
    }

    /// 草稿帧的物化**不带喂食**：它只把草稿物化上屏，不顺手把队列里的持久批喂进去。
    ///
    /// 两者混在一处时，界面看不出错，只表现为「草稿先、持久后」这条顺序偶尔反了 ——
    /// 而它正是「定稿到达时不闪」依赖的那条顺序。
    func testADraftMaterializationDoesNotFeedThePendingDurableBatch() async throws {
        func message(_ seq: Int) -> SessionEvent {
            SessionEvent(type: "user/message", seq: seq, time: Double(seq), data: .object([
                "id": .string("m-\(seq)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([.object(["type": .string("text"), "text": .string("持久-\(seq)")])]),
            ]))
        }
        // 基线之后通道期望 revision 1、下一个 chunk 位置 1。
        let chunk: JSONValue = .object([
            "type": .string("chunk"),
            "attemptId": .string("a-1"),
            "revision": .number(1),
            "index": .number(1),
            "time": .number(2),
            "chunk": .object([
                "type": .string("text-delta"),
                "index": .number(0),
                "text": .string("又说了一句"),
            ]),
        ])

        let sync = makeSync()
        sync.projection.apply(StreamReading(content: .opening(
            snapshot(cursor: 0, records: [], assistantStream: liveBaseline())
        )))
        XCTAssertTrue(assistantTexts(in: sync).contains("半句话"), "先确认草稿真的在")

        // 经输入单元直接进窗口：走 `.event` 会立刻开一次刷新闸，那样就造不出「有批未喂」这个状态。
        // 空窗口的 `start` 是 `cursor + 1`，所以第一条能进来的是 seq 1。
        _ = sync.input.append(message(1))
        XCTAssertEqual(texts(in: sync), [], "先确认它还没上屏")

        sync.projection.apply(StreamReading(content: .transient(chunk)))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(assistantTexts(in: sync).contains { $0.contains("又说了一句") },
                      "那一帧草稿本身没上屏 —— 下面那条「持久没上来」就成了空守")
        XCTAssertFalse(texts(in: sync).contains("持久-1"),
                       "草稿帧的物化把持久批一起喂了 —— 顺序从「草稿先、持久后」变成「一起到」")

        // 一条持久事件到达，刷新闸到点：两条才都在。
        sync.projection.apply(StreamReading(content: .event(message(2))))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(texts(in: sync), ["持久-1", "持久-2"], "刷新之后持久那一列该上屏")
    }

    /// 视图那一列里的消息正文。
    /// 一条用户消息记录 —— 需要「窗口里有一条」时用。
    private func userRecord(_ seq: Int) -> SessionRecord {
        SessionRecord(type: "user/message", event: SessionEvent(
            type: "user/message", seq: seq, time: Double(seq), data: .object([
                "id": .string("m-\(seq)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([.object(["type": .string("text"), "text": .string("第\(seq)条")])]),
            ])
        ))
    }

    private func texts(in sync: SessionSync) -> [String] {
        sync.nodes.compactMap { node -> String? in
            if case .message(let message) = node.data { return message.text }
            return nil
        }
    }

    /// 一份最小的打开帧夹具 —— 只给判据要用的四格。
    private func snapshot(cursor: Int, records: [SessionRecord],
                          projections: JSONValue = .object([:]),
                          hasMore: Bool = false,
                          assistantStream: JSONValue? = nil) -> SnapshotFrame {
        SnapshotFrame(
            header: SessionWireHeader(version: 1, id: "session-1", createdAt: 0, cwd: nil,
                                      parentSession: nil, isSeeded: false, origin: nil,
                                      delegationDepth: nil, agentPreset: nil),
            cursor: cursor,
            records: records,
            hasMore: hasMore,
            projections: ProjectionBlock(asOfSeq: cursor, values: projections),
            assistantStream: assistantStream
        )
    }

    /// 未定稿基线：一个进行中的 attempt，已累积一句「半句话」。
    ///
    /// 形状照 `TransientChannel.apply(baseline:)`：`revision` 是已见的最后一版，
    /// `activeAttempt.stream` 是**紧凑记录**（`text-chunks` 会被展开成 `text-delta`），
    /// `nextIndex` 是已累积的 chunk 数。
    private func liveBaseline(text: String = "半句话") -> JSONValue {
        .object([
            "revision": .number(0),
            "activeAttempt": .object([
                "attemptId": .string("a-1"),
                "turn": .number(1),
                "step": .number(1),
                "nextIndex": .number(1),
                "stream": .array([
                    .object([
                        "type": .string("text-chunks"),
                        "texts": .array([.string(text)]),
                        "time": .number(1),
                    ])
                ]),
            ]),
        ])
    }

    /// 快照里助手节点的正文（含 hidden 的中间步）。
    ///
    /// 不扫 `nodes`：那是可见集，而草稿是否可见由「这一步是不是末步」决定 —— 那是另一件事。
    /// 这组判据守的是「基线里的内容有没有被恢复进引擎」。
    private func assistantTexts(in sync: SessionSync) -> [String] {
        sync.snapshot.nodes.compactMap { node -> String? in
            if case .assistant(let assistant) = node.data { return assistant.text }
            return nil
        }
    }

    /// 这一组请求里，翻页发了几次。
    private func pageCalls() -> Int {
        ScriptedURLProtocol.snapshot().filter { $0.op == "session/page" }.count
    }

    /// 打开帧带的投影块是这一屏的初值 —— 当前模型与当前权限都从它起。
    ///
    /// control 是 App 级、开机就订上的；这一屏晚打开时它的 baseline 早已过去。只在 control
    /// 上取那两格的结果是它们一直显示 `--`，要等一次真正的变化才出现 —— 真机上「权限只剩
    /// 目录、当前档不显示」就是这个缺口。
    func testTheOpeningProjectionsSeedTheModelAndPermissionCells() {
        let sync = makeSync()
        var seeded: JSONValue?
        sync.onProjectionValues = { seeded = $0 }

        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 1, records: [], projections: .object([
            "modelSelection": .object([
                "lastUsed": .object(["provider": .string("deepseek"), "model": .string("chat")]),
                "next": .object(["provider": .string("deepseek"), "model": .string("reasoner")]),
            ]),
            "permissions": .object(["currentValue": .string("workspace-write")]),
        ])))))

        XCTAssertEqual(sync.displayedModel?.model, "reasoner", "当前模型从打开帧的投影起")
        XCTAssertEqual(seeded?["permissions"]?["currentValue"]?.string, "workspace-write",
                       "当前权限也从它起 —— 只靠 control 会让这一格一直是 --")
    }

    /// 一条实时事件只该碰它自己那一格 —— 走真接线（`feedEngine` → `refreshSnapshot`），
    /// 而不是在测试里另写一遍累积循环。接线断了（永远走全量）这里会是 201 而不是 1。
    ///
    /// 刷新走「一帧合并」，所以要等过一个合并窗口再读数：同一拍里读到的还是上一帧的值。
    func testOneAppendedEventMaterializesOneSlotNotTheWholeHistory() async throws {
        func message(_ seq: Int) -> SessionEvent {
            SessionEvent(type: "user/message", seq: seq, time: Double(seq), data: .object([
                "id": .string("m-\(seq)"),
                "source": .object(["kind": .string("user")]),
                "content": .array([.object(["type": .string("text"), "text": .string("x")])]),
            ]))
        }

        let sync = makeSync()
        let history = (1...200).map { SessionRecord(type: "user/message", event: message($0)) }
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 200, records: history))))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(sync.nodes.count, 200, "先确认这 200 条真的都进去了")

        let before = sync.buildViewNodeCount
        sync.projection.apply(StreamReading(content: .event(message(201))))
        try await Task.sleep(for: .milliseconds(60))
        let delta = sync.buildViewNodeCount - before

        XCTAssertEqual(sync.nodes.count, 201, "新的一条上了屏")
        XCTAssertEqual(delta, 1, "一条消息只重导一格；走全量会是 201")
    }

    /// 乐观行落在「最后一条持久事件之后、草稿之前」，而 `nodes` 整体按锚点升序。
    ///
    /// 三处都可能错而屏幕上看不出：行落在历史顶部（锚点取了 windowStart 而不是 frontier）、
    /// 行永远在末尾（排序键漏了它）、合并出来的列没排（两条来源直接拼接）。
    func testAnOptimisticRowSitsBetweenTheLastDurableEventAndTheDraft() async throws {
        func message(_ seq: Int) -> SessionRecord {
            SessionRecord(type: "user/message", event: SessionEvent(
                type: "user/message", seq: seq, time: Double(seq), data: .object([
                    "id": .string("m-\(seq)"),
                    "source": .object(["kind": .string("user")]),
                    "content": .array([.object(["type": .string("text"), "text": .string("持久-\(seq)")])]),
                ])
            ))
        }
        ScriptedURLProtocol.reset(replies: [
            "session/prompt": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"accepted":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        // 窗口 0…1、cursor 1 ⇒ frontier 2；草稿基线落在 frontier 之后。
        sync.projection.apply(StreamReading(content: .opening(snapshot(
            cursor: 1, records: [message(0), message(1)], assistantStream: liveBaseline()
        ))))
        let accepted = await sync.deliver(.prompt("hi"), mode: .queue)
        XCTAssertTrue(accepted)
        // 行之后再来一条持久的：它把「行在中间」这件事变成可观测的 —— 没有它，
        // 行的锚点即使落在最后（错法之一是「排序漏了它、直接拼在末尾」）也看不出来。
        sync.projection.apply(StreamReading(content: .event(message(2).event)))
        try await Task.sleep(for: .milliseconds(60))

        let row = try XCTUnwrap(sync.nodes.first { $0.businessId.hasPrefix("pending:") },
                                "乐观行没进视图那一列")
        let draft = try XCTUnwrap(sync.snapshot.nodes.first {
            if case .assistant = $0.data { return true }
            return false
        }, "草稿没进快照 —— 先确认夹具")

        XCTAssertGreaterThan(row.anchorSeq, 1, "行落在最后一条持久事件之前 —— 锚点取了窗口起点")
        XCTAssertLessThan(row.anchorSeq, draft.anchorSeq, "行落在草稿之后 —— 它会盖住正在写的那一段")

        let anchors = sync.nodes.map(\.anchorSeq)
        XCTAssertEqual(anchors, anchors.sorted(), "合并出来的列没按锚点排")
        XCTAssertNotEqual(sync.nodes.last?.businessId, row.businessId, "行被拼在了末尾 —— 排序漏了它")
    }

    /// 条数是「持久的那一半 + 乐观行」，两个来源各记一份就会不同步。
    func testMessageCountCountsTheOptimisticRowAndKeepsItAfterTheDurableOneArrives() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/prompt": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"accepted":true}}}"#
            ),
        ])
        let sync = makeScriptedSync()
        sync.projection.apply(StreamReading(content: .opening(snapshot(cursor: 4, records: []))))
        let durable = sync.messageCount

        let accepted = await sync.deliver(.prompt("你好"), mode: .queue)
        XCTAssertTrue(accepted)
        XCTAssertEqual(sync.messageCount, durable + 1, "发出去那一刻就该算上")

        let pending = try XCTUnwrap(sync.optimist.entries.first)
        sync.projection.apply(StreamReading(content: .event(SessionEvent(
            type: "user/message", seq: 5, time: 2,
            data: .object([
                "id": .string("m-1"),
                "source": .object(["kind": .string("user"), "rpcId": .string(pending.requestId)]),
                "content": .array([.object(["type": .string("text"), "text": .string("你好")])]),
            ])
        ))))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(sync.optimist.count, 0, "持久行认领之后乐观行退休")
        XCTAssertEqual(sync.messageCount, durable + 1, "换的是身份，不是条数")
    }

    /// 走真传输的 `SessionSync`（脚本化 URLProtocol）——「受理」这条分支需要真的回包。
    private func makeScriptedSync() -> SessionSync {        let configuration = URLSessionConfiguration.ephemeral
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

    /// 会话同步要两个真实依赖：连接（只用来取阶段）与一元客户端。
    /// 端点指向连不上的 `127.0.0.1:1`：这一组只喂帧，不发起请求。
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
