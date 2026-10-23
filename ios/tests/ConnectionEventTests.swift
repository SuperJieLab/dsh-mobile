/**
 * 事件流判读的判据 —— `ConnectionEventReader`（`Core/Gateway/ConnectionEvents/`）。
 *
 * 与 `SessionStreamReaderTests` 同一件事：给一段帧文本，判成什么、这条流接下来怎么办，
 * 不需要连接。差别在**值域更窄**：控制结局（`ready` 的代次、`refused` 的拒绝、`ended` 的
 * 收尾、`ignored` 的丢弃）、转发事件（`emit` 的名字与参数）、具名货物（`session-list` /
 * `waterfall` / `cancel` 三条 kind，载荷原样交出）。它不重放，所以没有窗口、没有水位、
 * 没有未定稿帧 —— 判读器也不该假装认识它们；货物的内容解释住各消费方，不在这里。
 *
 * 判据的来历是「认错了不会编译失败，也不会有哪条测试红」：认的是网关的 item 形状，一份会
 * 漂移的东西。样本按「读得出 / 读不出」两侧各给几个，别只给正向那半。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ConnectionEventTests: XCTestCase {

    private func read(_ text: String) throws -> ConnectionEventReading {
        let envelope = try JSONDecoder().decode(MuxServerEnvelope.self, from: Data(text.utf8))
        return ConnectionEventReader.read(envelope: envelope)
    }

    /// 可重试码恰好两个 —— 多一个或少一个，都要有人重新判一次「重试会不会变」。
    func testTheRetryableCodesAreExactlyTheTwoThatCanHeal() {
        XCTAssertEqual(ConnectionEventReading.retryableCodes, [
            GatewayErrorCode.sourceUnavailable.rawValue,
            GatewayErrorCode.internalError.rawValue,
        ])
    }

    // MARK: - O9：ready 带代次，缺席就是「源此刻没有活的代次」

    /// 两种 ready 都是合法状态，**不许把缺席补成 0 或 1**：代次是消费方判断「我这份基线还新不新」
    /// 的唯一依据，补一个数进去会让旧基线看起来是新的。
    func testReadyCarriesTheGenerationAndAbsenceStaysNil() throws {
        let withGeneration = try read(#"{"type":"item","streamId":"e1","payload":{"kind":"ready","generation":3}}"#)
        guard case .ready(let generation) = withGeneration.content else {
            return XCTFail("带代次的 ready 该判成 ready，实际：\(withGeneration.content)")
        }
        XCTAssertEqual(generation, 3)

        let withoutGeneration = try read(#"{"type":"item","streamId":"e1","payload":{"kind":"ready"}}"#)
        guard case .ready(let absent) = withoutGeneration.content else {
            return XCTFail("不带代次的 ready 同样是 ready，实际：\(withoutGeneration.content)")
        }
        XCTAssertNil(absent, "代次缺席表示源此刻没有活的代次 —— 不猜 0")
    }

    // MARK: - O9：emit 的名字与参数原样转出

    /// 网关已经把白名单筛过一遍，这里再筛一次就是第二份会漂的表，而它漂时只有「收不到」这一个信号。
    func testEmitKeepsNameAndArgsVerbatim() throws {
        let reading = try read("""
        {"type":"item","streamId":"e1","payload":
          {"kind":"emit","event":"api-session/added","args":["s9",{"nested":true}]}}
        """)

        guard case .emit(let name, let args) = reading.content else {
            return XCTFail("emit 该判成一条转发事件，实际：\(reading.content)")
        }
        XCTAssertEqual(name, "api-session/added", "名字原样 —— 大小写与斜杠都是上游的词汇")
        XCTAssertEqual(args.array?.count, 2, "参数原样，不拆不并")
        XCTAssertEqual(args.array?.first?.string, "s9")
        XCTAssertEqual(args.array?[1]["nested"]?.bool, true, "嵌套对象也原样")
    }

    /// `args` 在线上可能整段缺席（网关侧 `JSON.stringify` 会丢掉 `undefined` 字段）。
    /// 那不是坏帧：事件名已经说得清发生了什么，参数为空是它的真实取值。
    func testEmitWithoutArgsIsAnEmptyList() throws {
        let reading = try read(#"{"type":"item","streamId":"e1","payload":{"kind":"emit","event":"api-session/removed"}}"#)

        guard case .emit(let name, let args) = reading.content else {
            return XCTFail("没有参数的 emit 仍是一条事件，实际：\(reading.content)")
        }
        XCTAssertEqual(name, "api-session/removed")
        XCTAssertEqual(args.array, [], "缺席即空列表 —— 不补 null，也不丢整条事件")
    }

    /// 名字读不出就没法分派给任何人 —— 丢弃，不猜。这条流不重放，丢了就是永久丢，
    /// 所以它必须是「读不出才丢」，不是「不确定就丢」。
    func testEmitWithoutANameIsIgnored() throws {
        for text in [
            #"{"type":"item","streamId":"e1","payload":{"kind":"emit","event":42,"args":[]}}"#,
            #"{"type":"item","streamId":"e1","payload":{"kind":"emit","args":[]}}"#,
        ] {
            let reading = try read(text)
            guard case .ignored = reading.content else {
                return XCTFail("读不出事件名该丢弃，实际：\(reading.content)")
            }
        }
    }

    // MARK: - O9：认不出的不猜

    /// 五种「认不出」：别的 kind、`kind` 缺席、空载荷、缺载荷、未知的外壳类型。
    /// 一律 `.ignored` 且不动这条流。
    func testUnrecognizedFramesAreIgnored() throws {
        let cases: [(name: String, text: String)] = [
            ("别的 kind", #"{"type":"item","streamId":"e1","payload":{"kind":"watermark","seq":5}}"#),
            ("kind 缺席", #"{"type":"item","streamId":"e1","payload":{"event":"x","args":[]}}"#),
            ("空载荷", #"{"type":"item","streamId":"e1","payload":{}}"#),
            ("缺载荷", #"{"type":"item","streamId":"e1"}"#),
            ("未知外壳", #"{"type":"future-thing","streamId":"e1","payload":{"kind":"ready"}}"#),
        ]

        for item in cases {
            let reading = try read(item.text)
            guard case .ignored = reading.content else {
                return XCTFail("「\(item.name)」该被丢弃，实际：\(reading.content)")
            }
            XCTAssertEqual(reading.next, .keep, "「\(item.name)」不该让这条流改变动作")
            XCTAssertFalse(reading.establishes, "「\(item.name)」不是建成信号")
        }
    }

    // MARK: - O9：拒绝与收尾

    func testRefusalKeepsCodeAndMessage() throws {
        let reading = try read(#"{"type":"error","streamId":"e1","payload":{"code":"unknown-op","message":"no events"}}"#)

        guard case .refused(let failure) = reading.content else {
            return XCTFail("error 帧该判成拒绝，实际：\(reading.content)")
        }
        XCTAssertEqual(failure.code, "unknown-op")
        XCTAssertEqual(failure.message, "no events")
    }

    func testEndMeansReopen() throws {
        let reading = try read(#"{"type":"end","streamId":"e1"}"#)

        guard case .ended = reading.content else {
            return XCTFail("end 帧该判成收尾，实际：\(reading.content)")
        }
        XCTAssertEqual(reading.next, .reopen, "收尾之后要在同一条连接上重开")
    }

    // MARK: - 建成与动作：两条边界

    /// 建成只在 `ready` 上成立。写成「收到任何一帧即建成」的话，先到的 `emit` 会让心跳在源
    /// 还没有代次时就开始判死 —— 而这条流的 `ready` 是它的全部状态。
    func testOnlyReadyEstablishesTheStream() throws {
        let samples: [(name: String, text: String, establishes: Bool)] = [
            ("带代次的 ready", #"{"type":"item","streamId":"e1","payload":{"kind":"ready","generation":1}}"#, true),
            ("不带代次的 ready", #"{"type":"item","streamId":"e1","payload":{"kind":"ready"}}"#, true),
            ("emit", #"{"type":"item","streamId":"e1","payload":{"kind":"emit","event":"x","args":[]}}"#, false),
            ("收尾", #"{"type":"end","streamId":"e1"}"#, false),
            ("拒绝", #"{"type":"error","streamId":"e1","payload":{"code":"unknown-op","message":""}}"#, false),
            ("认不出", #"{"type":"item","streamId":"e1","payload":{"kind":"watermark"}}"#, false),
        ]

        for sample in samples {
            let reading = try read(sample.text)
            XCTAssertEqual(reading.establishes, sample.establishes, "「\(sample.name)」的建成判定不对")
        }
    }

    /// 拒绝按「重试之后结果会不会不同」分两支，不按错得多严重分：源没就绪、网关瞬时故障，
    /// 再开一条就可能好（`.retry`）；`unknown-op` 是「这台网关不认 events」，重开一万次
    /// 也一样（`.stop`）。两个动作在连接层都只作用于这一条流，连接不动。
    func testNextActionOfEachKind() throws {
        XCTAssertEqual(try read(#"{"type":"item","streamId":"e1","payload":{"kind":"ready","generation":1}}"#).next, .keep)
        XCTAssertEqual(try read(#"{"type":"item","streamId":"e1","payload":{"kind":"emit","event":"x","args":[]}}"#).next, .keep)
        XCTAssertEqual(try read(#"{"type":"item","streamId":"e1","payload":{"kind":"watermark"}}"#).next, .keep)
        // 两种审批货物是**内容**，不是「这条流该怎么办」：把它们判成 `.reopen` 会让一条
        // 收到审批的流当场重开，而症状是「卡片出现又消失」。
        XCTAssertEqual(try read(#"{"type":"item","streamId":"e1","payload":{"kind":"waterfall","eventId":"e1","agentId":"s1","request":{"toolName":"shell"}}}"#).next, .keep)
        XCTAssertEqual(try read(#"{"type":"item","streamId":"e1","payload":{"kind":"cancel","eventId":"e1"}}"#).next, .keep)
        XCTAssertEqual(try read(#"{"type":"end","streamId":"e1"}"#).next, .reopen)

        // 可重试的一类：再开一条可能就好（源刚就绪、网关瞬时故障）。
        for code in ["source-unavailable", "internal-error"] {
            let reading = try read("""
            {"type":"error","streamId":"e1","payload":{"code":"\(code)","message":""}}
            """)
            XCTAssertEqual(reading.next, .retry, "\(code)：退避重开这条流，别放弃")
        }
        // 真终态：重开一万次也一样。
        for code in ["unknown-op", "some-future-code"] {
            let reading = try read("""
            {"type":"error","streamId":"e1","payload":{"code":"\(code)","message":""}}
            """)
            XCTAssertEqual(reading.next, .stop, "\(code) 之后重开只会再收一次 —— 停这条流")
        }
    }

    // MARK: - 列表增量：具名货物与分派

    /// 第三种载荷：`session-list` 归成具名货物 —— kind 名与整段载荷原样交出。
    ///
    /// 这一条守的是整条链路的**中段** —— 网关已经把它发出来了，判读器若不认识，
    /// 列表永远收不到事件，而两端各自的判据都还是绿的。认不出的形状不在这里丢：
    /// 解释与丢弃住消费方（那边有自己的判据）。
    func testSessionListCargoIsHandedOverVerbatim() throws {
        let reading = try read("""
        {"type":"item","streamId":"e1","payload":{"kind":"session-list","change":{
          "kind":"activity","id":"s1","updatedAt":42}}}
        """)
        XCTAssertEqual(reading.content, .cargo(type: "session-list", payload: .object([
            "kind": .string("session-list"),
            "change": .object([
                "kind": .string("activity"), "id": .string("s1"), "updatedAt": .number(42),
            ]),
        ])))
        XCTAssertFalse(reading.establishes, "货物不建成这条流 —— 建成只由 ready 说")
        XCTAssertEqual(reading.next, .keep)

        // 载荷缺 `change` 也原样交出 —— 那是消费方要判的事。
        let bare = try read(#"{"type":"item","streamId":"e1","payload":{"kind":"session-list"}}"#)
        XCTAssertEqual(bare.content, .cargo(type: "session-list",
                                            payload: .object(["kind": .string("session-list")])))
    }

    /// 货物按 kind 名分派，与按事件名分派的那一组并列 —— 两个命名空间互不串。
    ///
    /// 撞名不是假想：将来上游真有一条叫 `cancel` 的事件时，它的 `emit` 进事件名口，
    /// 货物口的 `cancel` 听众不该被叫醒。
    func testCargoIsDispatchedByNameWithoutCrossingNamespaces() throws {
        let events = ConnectionEventStream()
        var seen: [JSONValue] = []
        events.onCargo("session-list") { seen.append($0) }

        events.handle(ConnectionEventReading(content: .cargo(
            type: "session-list", payload: .object(["change": .string("x")])
        )))
        XCTAssertEqual(seen.count, 1, "kind 名匹配才进这个听众")

        events.handle(ConnectionEventReading(content: .ready(generation: 1)))
        events.handle(ConnectionEventReading(content: .emit(name: "session-list", args: .array([]))))
        events.handle(ConnectionEventReading(content: .cargo(type: "waterfall", payload: .object([:]))))
        XCTAssertEqual(seen.count, 1, "别的内容与别的 kind 都不该进来 —— emit 名字同名也不串")

        var second = 0
        events.onCargo("session-list") { _ in second += 1 }
        events.handle(ConnectionEventReading(content: .cargo(
            type: "session-list", payload: .object(["change": .string("y")])
        )))
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(second, 1, "同一 kind 可以有两个听众 —— 注册表是复数")
    }

    // MARK: - O13：代次门槛

    /// 消费方只在「源说了一声」时被叫醒 —— `emit` 不算，`ready` 算，失效（不带代次）也算。
    ///
    /// 代次是消费方判断「我手里这份基线还新不新」的唯一依据。三条边界缺一不可：`emit`
    /// 不带代次（当它叫醒人就会变成「每帧重读一遍基线」）、新的代次算（去重读）、
    /// **失效也要通知**（此时能做的只有清空 —— 手里那些一条都答不了）。
    func testGenerationHandlersFirePerReadyIncludingSourceLoss() {
        let events = ConnectionEventStream()
        var seen: [Int?] = []
        events.onGeneration { seen.append($0) }

        events.handle(ConnectionEventReading(content: .emit(
            name: "api-session/added", args: .array([.string("s9")])
        )))
        XCTAssertEqual(seen, [], "emit 不带代次 —— 不该让它去重读基线")

        events.handle(ConnectionEventReading(content: .ready(generation: 3)))
        XCTAssertEqual(seen, [3], "源第一次就绪要通知一次")

        events.handle(ConnectionEventReading(content: .ready(generation: 4)))
        XCTAssertEqual(seen, [3, 4], "源重建之后是新的代次，再通知一次")

        events.handle(ConnectionEventReading(content: .ready(generation: nil)))
        XCTAssertEqual(seen.count, 3, "源失效也要通知 —— 消费方据此清空手里的基线")
        XCTAssertNil(seen.last ?? 0, "失效那一次不带代次")
        XCTAssertNil(events.generation, "失效之后手里不能还留着一个看着有效的代次")
    }

    // MARK: - O14：按名字注册

    /// 分派是查表，不是 switch：换个名字、加一个新名字都不需要改这里。
    ///
    /// 样本用两个**上游真有的**名字加一个**谁都不知道的**名字：前两个说明名字原样匹配，
    /// 第三个说明「新增一类事件」在消费方这一侧零成本 —— 谁把分派写成 switch，第三个名字
    /// 就没有分支可走，那时红的是这条。
    func testConsumersAreMatchedByNameWithoutADispatchTable() {
        let events = ConnectionEventStream()
        var added = 0
        var removed: [JSONValue] = []
        events.on("api-session/added") { _ in added += 1 }
        events.on("api-session/removed") { removed.append($0) }

        events.handle(ConnectionEventReading(content: .emit(
            name: "api-session/removed", args: .array([.string("s9")])
        )))
        XCTAssertEqual(added, 0, "别的名字不该串到它这里")
        XCTAssertEqual(removed, [.array([.string("s9")])], "参数原样交给消费方")

        var unheard = 0
        events.on("some/future-event") { _ in unheard += 1 }
        events.handle(ConnectionEventReading(content: .emit(
            name: "some/future-event", args: .array([])
        )))
        XCTAssertEqual(unheard, 1, "新名字注册即可收到 —— 分派不该是一张要跟着改的表")

        // 同一类事件可以有两个听众：注册表是复数，不是「一格一个」。
        var second = 0
        events.on("api-session/added") { _ in second += 1 }
        events.handle(ConnectionEventReading(content: .emit(
            name: "api-session/added", args: .array([])
        )))
        XCTAssertEqual(added, 1)
        XCTAssertEqual(second, 1, "第二个听众也该收到")
    }

    // MARK: - 登记这条流：判读结论要真的变成连接层的答复

    /// 造流口的替身：只记账，不含任何判定。
    ///
    /// 用它而不是真的 `GatewayHost`：后者要一个 `RpcClient`（真 `URLSession` 路径），
    /// 于是「判读结论怎么变成流层的答复」这一跳就没有任何办法被断言 —— 而它正是
    /// `read` 与 `handle` 两组判据之间唯一的缝。
    @MainActor
    private final class RecordingFactory: StreamFactory {
        var behaviors: [any StreamBehavior] = []
        func makeStream(_ behavior: any StreamBehavior) -> LogicalStream? {
            behaviors.append(behavior)
            return nil   // 本组不验流表，只需要「造流被调用了一次」
        }
    }

    /// 登记的那一条流：开流文本是 `{op:"events"}`，答复由判读结论翻译而来。
    ///
    /// 这一跳改错的方向全是静默的：`establishes: true` 恒真会让 `emit` 也叫建成（心跳在源
    /// 还没有代次时开始判死）；`next` 传成常量 `.keep` 会让收尾不重开、被拒不收起。
    func testAttachRegistersOneStreamWhoseBuildAndReplyFollowTheReading() throws {
        let events = ConnectionEventStream()
        let factory = RecordingFactory()
        events.attach(to: factory)

        XCTAssertEqual(factory.behaviors.count, 1, "attach 造一条，不多不少")
        let behavior = try XCTUnwrap(factory.behaviors.first)
        XCTAssertEqual(behavior.label, "connection-events")

        XCTAssertEqual(try behavior.build("e1"),
                       #"{"payload":{"op":"events"},"streamId":"e1","type":"open"}"#,
                       "这条流不绑会话：载荷里只有 op")

        func reply(_ frame: String) throws -> StreamReply {
            let data = Data(frame.utf8)
            let envelope = try JSONDecoder().decode(MuxServerEnvelope.self, from: data)
            return behavior.handle(envelope, raw: data)
        }

        let ready = try reply(#"{"type":"item","streamId":"e1","payload":{"kind":"ready","generation":2}}"#)
        XCTAssertTrue(ready.establishes, "`ready` 才算建成")
        XCTAssertEqual(ready.next, .keep)

        let emit = try reply(#"{"type":"item","streamId":"e1","payload":{"kind":"emit","event":"x","args":[]}}"#)
        XCTAssertFalse(emit.establishes, "`emit` 不算建成 —— 源可能还没有代次")

        let refused = try reply(#"{"type":"error","streamId":"e1","payload":{"code":"unknown-op","message":""}}"#)
        XCTAssertFalse(refused.establishes)
        XCTAssertEqual(refused.next, .stop, "被拒即停；传成 `.keep` 会让它永远没有下文")

        let ended = try reply(#"{"type":"end","streamId":"e1"}"#)
        XCTAssertEqual(ended.next, .reopen, "收尾要在同一条连接上重开")
    }
}
