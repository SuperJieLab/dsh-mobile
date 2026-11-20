/**
 * 入站帧形状的判据 —— `InboundFrame`（`LongConnection/Wire/MuxFrames.swift`）。
 *
 * 这一组测的事只有一件：**一段线上文本，外壳与载荷各被认成什么**。
 * 它是「一帧只解析一次」的落点：分派靠 key 存在性，不被认出的形状落到 `nil`，
 * 判读层再把它归成 `.ignored`。
 *
 * 顺序也是契约：同一帧同时满足两条判据时，取表里靠前的那一条。改了顺序不会编译失败，
 * 只会让某一类帧悄悄换支 —— 所以 `testKindWinsOverEventShape` 把它钉住。
 */
import Foundation
import XCTest

@testable import DshMobile

final class InboundFrameTests: XCTestCase {

    private func decode(_ text: String) throws -> InboundFrame {
        try XCTUnwrap(InboundFrame.decode(Data(text.utf8)),
                      "这一帧该解得开：\(text.prefix(80))")
    }

    // MARK: - 外壳

    func testEnvelopeCarriesTypeStreamIdAndByteCount() throws {
        let text = #"{"type":"end","streamId":"s-7"}"#
        let frame = try decode(text)

        XCTAssertEqual(frame.type, "end")
        XCTAssertEqual(frame.streamId, "s-7")
        XCTAssertEqual(frame.byteCount, Data(text.utf8).count,
                       "字节数要随帧带出 —— `recordPerf` 用它，缺了会静默变 0")
        XCTAssertNil(frame.payload)
    }

    /// 外壳缺 `streamId` 就不是一条可路由的帧：整帧丢，不是当作「认不出的载荷」。
    func testAFrameWithoutStreamIdIsNotDecodable() {
        XCTAssertNil(InboundFrame.decode(Data(#"{"type":"end"}"#.utf8)))
        XCTAssertNil(InboundFrame.decode(Data("not json at all".utf8)))
    }

    // MARK: - 载荷四支

    /// O1：`snapshot` → 打开帧，载荷直解成强类型。
    func testOpeningPayloadIsStronglyTyped() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","value":{
          "type":"snapshot","sessionId":"s-1","pageStart":2,"cursor":5,"hasOlder":true,
          "events":[{"type":"user/message","seq":2,"time":1700000000000,"data":{}}]}}
        """)

        guard case .item(.follow(.opening(let payload))) = frame.payload else {
            return XCTFail("snapshot 该归 opening，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(payload.cursor, 5)
        XCTAssertEqual(payload.events?.compactMap(\.value).map(\.seq), [2])
    }

    /// O2：`event` → 事件帧，本体是 `event` 那一格里的 `SessionEvent`。
    func testEventPayloadIsStronglyTyped() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","value":{"type":"event","event":
          {"type":"user/message","seq":7,"time":1700000000000,"data":{}}}}
        """)

        guard case .item(.follow(.sessionEvent(let event))) = frame.payload else {
            return XCTFail("event 该归 sessionEvent，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(event.type, "user/message")
        XCTAssertEqual(event.seq, 7)
    }

    /// O3：`assistant-stream` 不带 `seq`，且必须排在事件帧之前被认出来。
    func testTransientPayloadKeepsItsInnerFrame() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","value":
          {"type":"assistant-stream","frame":{"type":"chunk","revision":3,"index":2}}}
        """)

        guard case .item(.follow(.transient(let inner))) = frame.payload else {
            return XCTFail("assistant-stream 该归 transient，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(inner["type"]?.string, "chunk")
        XCTAssertEqual(inner["index"]?.int, 2)
    }

    /// `$events` 的货物：按 `type` 取支，`ready` 带 `clientId`。
    func testEventsPayloadIsDiscriminatedByType() throws {
        let frame = try decode("""
        {"type":"item","streamId":"e-1","value":{"type":"ready","clientId":"c-1"}}
        """)

        guard case .item(.events(.ready(let clientId))) = frame.payload else {
            return XCTFail("ready 该归 events，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(clientId, "c-1")
    }

    // MARK: - 非 item 外壳

    func testErrorFrameIsRefused() throws {
        let frame = try decode("""
        {"type":"error","streamId":"s-1","error":{"code":"window-too-large","message":"窗口太大","details":{}}}
        """)

        guard case .refused(let failure) = frame.payload else {
            return XCTFail("error 帧该归 refused，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(failure.code, "window-too-large")
        XCTAssertEqual(failure.message, "窗口太大")
    }

    // MARK: - 认不出的载荷

    /// 两类要分开，判据不同：
    ///
    /// - **解不出**（缺 `type`）：`payload == nil` 且 `payloadRejected == true` —— 要留痕，
    ///   否则「对端还在说旧协议」与「这一帧坏了」在日志里都等于什么都没发生。
    /// - **不认识**（`type` 不认识）：落 `.unknown` 且原样载荷带着 —— 那是新版本的货物，
    ///   旧客户端该忽略它，但要知道丢的是哪一种（S6 的「可见」）。
    func testUnparsableItemPayloadsAreMarkedAndUnknownsAreKept() throws {
        let unparsable: [(name: String, payload: String)] = [
            ("空对象", "{}"),
            ("没有 type", #"{"sessionId":"s-1","cursor":1}"#),
        ]
        for item in unparsable {
            let frame = try decode(#"{"type":"item","streamId":"s-1","value":\#(item.payload)}"#)
            XCTAssertNil(frame.payload, "「\(item.name)」该是 nil，实际：\(String(describing: frame.payload))")
            XCTAssertTrue(frame.payloadRejected, "「\(item.name)」解不出要留痕")
        }

        let unknown: [(name: String, payload: String, type: String)] = [
            ("只有未知 type", #"{"type":"odd"}"#, "odd"),
            ("未知 type 带载荷", #"{"type":"future-thing","data":{}}"#, "future-thing"),
        ]
        for item in unknown {
            let frame = try decode(#"{"type":"item","streamId":"s-1","value":\#(item.payload)}"#)
            guard case .item(.unknown(let cargo)) = frame.payload else {
                return XCTFail("「\(item.name)」该落 unknown，实际：\(String(describing: frame.payload))")
            }
            XCTAssertEqual(cargo["type"]?.string, item.type,
                           "原样载荷要带着 —— 留痕时能看出丢的是哪一种")
            XCTAssertFalse(frame.payloadRejected, "不认识不是解不出，不该置留痕标记")
        }
    }

    /// 未定稿帧缺内层 `frame` 是常态（上游没带未定稿内容），给 `.null` 而不是判成坏帧 ——
    /// 判成坏帧会让「正在生成」那一段的清除时机整个变掉。
    func testTransientWithoutInnerFrameFallsBackToNull() throws {
        let frame = try decode(#"{"type":"item","streamId":"s-1","value":{"type":"assistant-stream"}}"#)

        guard case .item(.follow(.transient(let inner))) = frame.payload else {
            return XCTFail("缺 frame 仍该归 transient，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(inner, .null)
    }

    /// 判据 7 的流那一半：`details` 要解出来，缺了给空字典 ——
    /// 与一元那边的 `GatewayFailure` 同一套规则，两条通道对同一格不能一个严一个宽。
    func testErrorFrameCarriesDetails() throws {
        let withDetails = try decode(
            #"{"type":"error","streamId":"s-1","error":{"code":"internal-error","message":"x","details":{"field":"cursor"}}}"#
        )
        guard case .refused(let failure) = withDetails.payload else {
            return XCTFail("error 帧该归 refused")
        }
        XCTAssertEqual(failure.details["field"], .string("cursor"))

        let withoutDetails = try decode(
            #"{"type":"error","streamId":"s-1","error":{"code":"internal-error","message":"x"}}"#
        )
        guard case .refused(let missing) = withoutDetails.payload else {
            return XCTFail("缺 details 仍是可读的拒绝")
        }
        XCTAssertEqual(missing.details, [:], "缺这一格不整条失败")
    }

    /// `error` 帧缺 `message` 时 `code` 必须活下来。
    /// 整包解不出会把 `window-too-large` 从「会话级终态」降成「可重试」，语义正好反了。
    func testErrorWithoutMessageKeepsItsCode() throws {
        let frame = try decode(#"{"type":"error","streamId":"s-1","error":{"code":"window-too-large"}}"#)

        guard case .refused(let failure) = frame.payload else {
            return XCTFail("缺 message 仍该归 refused，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(failure.code, "window-too-large")
        XCTAssertEqual(failure.message, "")
    }

    /// 三字段都在但类型不对：要留标记，否则判读层那条「开流超时第一现场」的 warn 没有落点。
    /// 与「四支都不匹配」分开 —— 那一种是本版不认识的新形状，静默丢弃才对。
    func testBrokenOpeningShapeIsMarked() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","value":{"type":"snapshot","sessionId":"s-1","cursor":"oops","events":[]}}
        """)

        XCTAssertNil(frame.payload, "类型不对就不该成形")
        XCTAssertTrue(frame.payloadRejected, "「解不出」与「不认识」要分得开")
    }

    // MARK: - 判别契约
    /// **只看 `value.type`**：别的键（`seq`、`kind`）不参与分派。
    ///
    /// 旧实现的四条判据按书写顺序互相遮挡，改顺序不编译失败、只会让某类帧悄悄换支。
    /// 现在这一格是唯一的判别字段 —— 加多少别的键都不会改变它落到哪一支。
    func testTypeIsTheOnlyDiscriminator() throws {
        let frame = try decode("""
        {"type":"item","streamId":"e-1","value":{"type":"ready","clientId":"c-1","seq":9,"kind":"emit","event":"x"}}
        """)

        guard case .item(.events(.ready(let clientId))) = frame.payload else {
            return XCTFail("type 说 ready 就该归 ready，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(clientId, "c-1", "type 是唯一判别字段，别的键不参与分派")
    }
    /// 判据 2 的覆盖面：三条流的九种货物**各有一支自己的落点**。
    ///
    /// 只验 `ready` 一支时，加一种货物而漏写分支看不出差别 —— 那一帧会被 `default`
    /// 接成 `unknown`，而 `unknown` 也是「合法」的落点，测试照样绿。
    func testEveryCargoHasItsOwnBranch() throws {
        let cases: [(name: String, value: String, branch: String)] = [
            ("follow 的快照", #"{"type":"snapshot","sessionId":"s-1","cursor":1,"events":[]}"#, "follow.opening"),
            ("follow 的事件", #"{"type":"event","event":{"type":"user/message","seq":1,"time":1,"data":{}}}"#, "follow.event"),
            ("follow 的未定稿", #"{"type":"assistant-stream","frame":{}}"#, "follow.transient"),
            ("events 的 ready", #"{"type":"ready","clientId":"c-1"}"#, "events.ready"),
            ("events 的 emit", #"{"type":"emit","event":"x","args":[]}"#, "events.emit"),
            ("events 的待答", #"{"type":"waterfall","event":"approval/request","eventId":"e-1","agentId":"a-1","request":{}}"#, "events.waterfall"),
            ("events 的撤回", #"{"type":"cancel","eventId":"e-1"}"#, "events.cancel"),
            ("control 的基线", #"{"type":"baseline","value":{"projections":{"s-1":{"asOfSeq":3,"values":{}}}}}"#, "control.baseline"),
            ("control 的增量", #"{"type":"projection","sessionId":"s-1","seq":3,"changes":[{"key":"title","val":"x"}]}"#, "control.projection"),
        ]

        for item in cases {
            let frame = try decode(#"{"type":"item","streamId":"s-1","value":\#(item.value)}"#)
            XCTAssertEqual(Self.branchName(frame.payload), item.branch,
                           "「\(item.name)」落错了支，实际：\(String(describing: frame.payload))")
            XCTAssertFalse(frame.payloadRejected, "「\(item.name)」是合法货物，不该被判成解不出")
        }
    }

    /// 载荷落在哪一支 —— 给上面那张表一个可断言的标签。
    private static func branchName(_ payload: InboundPayload?) -> String {
        switch payload {
        case .some(.item(.follow(.opening))): return "follow.opening"
        case .some(.item(.follow(.sessionEvent))): return "follow.event"
        case .some(.item(.follow(.transient))): return "follow.transient"
        case .some(.item(.events(.ready))): return "events.ready"
        case .some(.item(.events(.emit))): return "events.emit"
        case .some(.item(.events(.waterfall))): return "events.waterfall"
        case .some(.item(.events(.cancel))): return "events.cancel"
        case .some(.item(.control(.baseline))): return "control.baseline"
        case .some(.item(.control(.projection))): return "control.projection"
        case .some(.item(.unknown)): return "unknown"
        case .some(.refused): return "refused"
        case .none: return "nil"
        }
    }

    /// 判据 4：旧形状 `{payload:…}` 必须判读失败**并留痕**。
    ///
    /// 静默丢弃是这条判据要防的那件事：它会让「对端还在说旧协议」表现得和「这一帧坏了」
    /// 一样 —— 什么都不发生。`payloadRejected` 是那条痕迹的开关。
    func testLegacyPayloadShapeIsRejectedAndMarked() throws {
        let frame = try decode(#"{"type":"item","streamId":"s-1","payload":{"sessionId":"s-1","cursor":1,"events":[]}}"#)
        XCTAssertNil(frame.payload, "旧形状不许被当成一种新货物")
        XCTAssertTrue(frame.payloadRejected, "解不出要留痕 —— 否则旧协议在日志里看不见")
    }

}
