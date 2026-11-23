/**
 * 入站帧形状的判据 —— `InboundFrame`（`LongConnection/Wire/MuxFrames.swift`）
 * 与三条流各自的货物读法。
 *
 * 这一组测的事只有一件：**一段线上文本，外壳被认成什么、每条流认出自己的哪种货物**。
 * 判别字段仍然只有 `value.type` 一格；变的是这张表由谁读 —— 从前是一张全局表，现在每条流
 * 各读各的。同名字段在两条流上形状不同（`baseline`）时，全局表只能容下一种，另一条流的
 * 收端连一行代码都跑不到。
 *
 * 顺序不再是契约（没有第二张表可以去遮挡第一条），换成 `testEachStreamOnlyTakesItsOwnCargo`：
 * 每条流只认自己那几种货物，别的流的货物落到 `.foreign`。
 */
import Foundation
import XCTest

@testable import DshMobile

final class InboundFrameTests: XCTestCase {

    private func decode(_ text: String) throws -> InboundFrame {
        try XCTUnwrap(InboundFrame.decode(Data(text.utf8)),
                      "这一帧该解得开：\(text.prefix(80))")
    }

    private func jsonValue(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// 一条 `item` 帧的货物原文 —— 与生产同一条路（外壳解一次，货物留原文）。
    private func cargo(of text: String) throws -> JSONValue {
        try XCTUnwrap(try decode(text).value, "这一帧该带着货物原文")
    }

    // MARK: - 外壳

    func testEnvelopeCarriesTypeStreamIdAndByteCount() throws {
        let text = #"{"type":"end","streamId":"s-7"}"#
        let frame = try decode(text)

        XCTAssertEqual(frame.type, "end")
        XCTAssertEqual(frame.streamId, "s-7")
        XCTAssertEqual(frame.byteCount, Data(text.utf8).count,
                       "字节数要随帧带出 —— `recordPerf` 用它，缺了会静默变 0")
        XCTAssertNil(frame.value, "没有货物的帧不该凭空有一格")
        XCTAssertNil(frame.failure)
    }

    /// 外壳缺 `streamId` 就不是一条可路由的帧：整帧丢，不是当作「认不出的载荷」。
    func testAFrameWithoutStreamIdIsNotDecodable() {
        XCTAssertNil(InboundFrame.decode(Data(#"{"type":"end"}"#.utf8)))
        XCTAssertNil(InboundFrame.decode(Data("not json at all".utf8)))
    }

    /// **连接层不择型**：`item` 只把 `value` 解成通用树，`type` 只为留痕可读。
    ///
    /// 这条守的是这次改动本身：`InboundFrame` 一旦替某条流认了货物，另一条流的同名货物
    /// 就又会被它挡住。
    func testAnItemFrameKeepsItsCargoUnread() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","value":{
          "type":"snapshot","sessionId":"s-1","cursor":5,"events":[]}}
        """)

        XCTAssertEqual(frame.type, "item")
        XCTAssertEqual(try XCTUnwrap(frame.value)["type"]?.string, "snapshot",
                       "货物原文原样带着，连接层只读得到一个 `type` 字符串")
    }

    // MARK: - `session/follow` 的三种货物

    /// O1：`snapshot` → 打开帧，载荷直解成强类型。
    func testOpeningPayloadIsStronglyTyped() throws {
        let value = try cargo(of: """
        {"type":"item","streamId":"s-1","value":{
          "type":"snapshot","sessionId":"s-1","pageStart":2,"cursor":5,"hasOlder":true,
          "events":[{"type":"user/message","seq":2,"time":1700000000000,"data":{}}]}}
        """)

        guard case .decoded(.opening(let payload)) = FollowItem.read(value) else {
            return XCTFail("snapshot 该归 opening")
        }
        XCTAssertEqual(payload.cursor, 5)
        XCTAssertEqual(payload.events?.compactMap(\.value).map(\.seq), [2],
                       "坏事件单条跳过，好事件照常解 —— 与 `FailableDecodable` 同一口径")
    }

    /// O2：`event` → 事件帧，本体是 `event` 那一格里的 `SessionEvent`。
    func testEventPayloadIsStronglyTyped() throws {
        let value = try cargo(of: """
        {"type":"item","streamId":"s-1","value":{"type":"event","event":
          {"type":"user/message","seq":7,"time":1700000000000,"data":{}}}}
        """)

        guard case .decoded(.sessionEvent(let event)) = FollowItem.read(value) else {
            return XCTFail("event 该归 sessionEvent")
        }
        XCTAssertEqual(event.type, "user/message")
        XCTAssertEqual(event.seq, 7)
    }

    /// O3：`assistant-stream` 与事件帧同在一个类型上，但判别只看 `type`。
    func testTransientPayloadKeepsItsInnerFrame() throws {
        let value = try cargo(of: """
        {"type":"item","streamId":"s-1","value":
          {"type":"assistant-stream","frame":{"type":"chunk","revision":3,"index":2}}}
        """)

        guard case .decoded(.transient(let inner)) = FollowItem.read(value) else {
            return XCTFail("assistant-stream 该归 transient")
        }
        XCTAssertEqual(inner["type"]?.string, "chunk")
        XCTAssertEqual(inner["index"]?.int, 2)
    }

    /// 未定稿帧缺内层 `frame` 是常态（上游没带未定稿内容），给 `.null` 而不是判成坏帧 ——
    /// 判成坏帧会让「正在生成」那一段的清除时机整个变掉。
    func testTransientWithoutInnerFrameFallsBackToNull() throws {
        let value = try cargo(of: #"{"type":"item","streamId":"s-1","value":{"type":"assistant-stream"}}"#)

        guard case .decoded(.transient(let inner)) = FollowItem.read(value) else {
            return XCTFail("缺 frame 仍该归 transient")
        }
        XCTAssertEqual(inner, .null)
    }

    // MARK: - `$events` 的货物

    /// `ready` 是唯一一条建成信号，`clientId` 必须带出来 —— 应答审批要靠它登记。
    func testEventsPayloadIsDiscriminatedByType() throws {
        let value = try cargo(of: """
        {"type":"item","streamId":"e-1","value":{"type":"ready","clientId":"c-1"}}
        """)

        guard case .decoded(.ready(let clientId)) = EventsItem.read(value) else {
            return XCTFail("ready 该归 events")
        }
        XCTAssertEqual(clientId, "c-1")
    }

    /// **只看 `value.type`**：别的键（`seq`、`kind`、`event`）不参与分派。
    func testTypeIsTheOnlyDiscriminator() throws {
        let value = try cargo(of: """
        {"type":"item","streamId":"e-1","value":{"type":"ready","clientId":"c-1","seq":9,"kind":"emit","event":"x"}}
        """)

        guard case .decoded(.ready(let clientId)) = EventsItem.read(value) else {
            return XCTFail("type 说 ready 就该归 ready")
        }
        XCTAssertEqual(clientId, "c-1", "type 是唯一判别字段，别的键不参与分派")
    }

    // MARK: - 每条流只认自己的货物（判据 16）

    /// 一个 cargo 值在每条流上的归属 —— **同名字段不同形状的那一格不再互相遮挡**。
    ///
    /// 这张表就是「按流解码」的理由：`baseline` 在 `session/control` 上是投影表、在
    /// `workspace/follow` 上是组清单；从前那张全局表按 `value.type` 一分派，`control` 那条
    /// 分支就会强解 `value.projections`，组流的基线在解码层被当成坏帧丢掉，收端一行都跑不到。
    func testEachStreamOnlyTakesItsOwnCargo() throws {
        let cases: [(name: String, json: String, follow: String, events: String, control: String)] = [
            ("follow 的快照", #"{"type":"snapshot","sessionId":"s-1","cursor":1,"events":[]}"#,
             "follow.opening", "foreign", "foreign"),
            ("follow 的事件", #"{"type":"event","event":{"type":"user/message","seq":1,"time":1,"data":{}}}"#,
             "follow.event", "foreign", "foreign"),
            ("events 的 ready", #"{"type":"ready","clientId":"c-1"}"#,
             "foreign", "events.ready", "foreign"),
            ("events 的 emit", #"{"type":"emit","event":"x","args":[]}"#,
             "foreign", "events.emit", "foreign"),
            ("control 的基线", #"{"type":"baseline","value":{"projections":{"s-1":{"asOfSeq":3,"values":{}}}}}"#,
             "foreign", "foreign", "control.baseline"),
            ("control 的增量", #"{"type":"projection","sessionId":"s-1","seq":3,"changes":[{"key":"title","val":"x"}]}"#,
             "foreign", "foreign", "control.projection"),
        ]

        for item in cases {
            let value = try jsonValue(item.json)
            XCTAssertEqual(Self.followName(FollowItem.read(value)), item.follow, "\(item.name) → follow")
            XCTAssertEqual(Self.eventsName(EventsItem.read(value)), item.events, "\(item.name) → events")
            XCTAssertEqual(Self.controlName(ControlValue.read(value)), item.control, "\(item.name) → control")
        }
    }

    /// 「丢掉的到底是哪一种」要读得出来 —— S6 的「可见」落在 `.foreign` 带的那一格上。
    func testForeignCargoCarriesItsTypeForTheLog() throws {
        let value = try jsonValue(#"{"type":"future-thing","data":{}}"#)

        guard case .foreign(let type) = FollowItem.read(value) else {
            return XCTFail("新货物该落 foreign")
        }
        XCTAssertEqual(type, "future-thing", "痕迹里要带上货物自己的 `type`")
        guard case .foreign(nil) = FollowItem.read(try jsonValue(#"{"sessionId":"s-1"}"#)) else {
            return XCTFail("连 `type` 都没有也是 foreign，而不是解出了什么")
        }
    }

    // MARK: - 解不出与本流无关要分开

    /// 是本流的 `type`、字段坏了 → `.unparsable`（留痕）；不是本流的 → `.foreign`（丢弃即可）。
    ///
    /// 合成一种的话，「协议漂移」与「串流」在日志里长得一样，而它们要查的地方不同。
    func testUnparsableCargoIsMarkedSeparatelyFromForeign() throws {
        let broken = try jsonValue(
            #"{"type":"snapshot","sessionId":"s-1","cursor":"oops","events":[]}"#
        )
        guard case .unparsable = FollowItem.read(broken) else {
            return XCTFail("本流的 type、字段不对 → unparsable")
        }

        let brokenEvent = try jsonValue(
            #"{"type":"event","event":{"type":"user/message","seq":"oops","time":1,"data":{}}}"#
        )
        guard case .unparsable = FollowItem.read(brokenEvent) else {
            return XCTFail("事件体坏了也是 unparsable，不是 foreign")
        }

        guard case .unparsable = ControlValue.read(
            try jsonValue(#"{"type":"baseline","value":{}}"#)
        ) else {
            return XCTFail("baseline 缺 projections → unparsable")
        }
    }

    /// 打开帧三字段齐全才成形：缺 `cursor` / `sessionId` / `events` 任一，`frame()` 给 nil。
    ///
    /// 三个字段分开断言：它们是同一个 `guard` 的三段，而「只写了第一段」的写法在别的两支上
    /// 会静默放过 —— 一条事件帧于是被当成 opening、把窗口清空。
    func testOpeningWithoutItsRequiredFieldsIsNotAnOpening() throws {
        let cases: [(name: String, payload: String)] = [
            ("cursor", #"{"sessionId":"s-1","pageStart":0,"events":[]}"#),
            ("sessionId", #"{"pageStart":0,"cursor":2,"events":[]}"#),
            ("events", #"{"sessionId":"s-1","pageStart":0,"cursor":2}"#),
        ]

        for item in cases {
            let value = try jsonValue(#"{"type":"snapshot",\#(item.payload.dropFirst())}"#)
            guard case .decoded(.opening(let shape)) = FollowItem.read(value) else {
                return XCTFail("「\(item.name)」该仍归 opening（载荷本身可解）")
            }
            XCTAssertNil(shape.frame(), "缺 \(item.name) 仍被当成打开窗口 —— 路由判据被放宽了")
        }
    }

    // MARK: - 非 item 外壳

    func testErrorFrameIsRefused() throws {
        let frame = try decode("""
        {"type":"error","streamId":"s-1","error":{"code":"window-too-large","message":"窗口太大","details":{}}}
        """)

        let failure = try XCTUnwrap(frame.failure, "error 帧该带失败")
        XCTAssertEqual(failure.code, "window-too-large")
        XCTAssertEqual(failure.message, "窗口太大")
        XCTAssertNil(frame.value, "error 帧没有货物原文")
    }

    /// 判据 7 的流那一半：`details` 要解出来，缺了给空字典 ——
    /// 与一元那边的 `GatewayFailure` 同一套规则，两条通道对同一格不能一个严一个宽。
    func testErrorFrameCarriesDetails() throws {
        let withDetails = try decode(
            #"{"type":"error","streamId":"s-1","error":{"code":"internal-error","message":"x","details":{"field":"cursor"}}}"#
        )
        XCTAssertEqual(try XCTUnwrap(withDetails.failure).details["field"], .string("cursor"))

        let withoutDetails = try decode(
            #"{"type":"error","streamId":"s-1","error":{"code":"internal-error","message":"x"}}"#
        )
        XCTAssertEqual(try XCTUnwrap(withoutDetails.failure).details, [:], "缺这一格不整条失败")
    }

    /// `error` 帧缺 `message` 时 `code` 必须活下来。
    /// 整包解不出会把 `window-too-large` 从「会话级终态」降成「可重试」，语义正好反了。
    func testErrorWithoutMessageKeepsItsCode() throws {
        let frame = try decode(#"{"type":"error","streamId":"s-1","error":{"code":"window-too-large"}}"#)

        let failure = try XCTUnwrap(frame.failure, "缺 message 仍是可读的拒绝")
        XCTAssertEqual(failure.code, "window-too-large")
        XCTAssertEqual(failure.message, "")
    }

    // MARK: - 旧形状

    /// 判据 4：旧形状 `{payload:…}` 没有 `value` —— 收端据此留痕。
    ///
    /// 静默丢弃是这条判据要防的那件事：它会让「对端还在说旧协议」表现得和「这一帧坏了」
    /// 一样 —— 什么都不发生。
    func testLegacyPayloadShapeCarriesNoValue() throws {
        let frame = try decode(#"{"type":"item","streamId":"s-1","payload":{"sessionId":"s-1","cursor":1,"events":[]}}"#)
        XCTAssertNil(frame.value, "旧形状不许被当成一种新货物")
    }

    /// `value` 是 `null` 时同样读不出货物 —— 但它**在**（不是缺席），所以不是同一种坏事。
    func testNullValueHasNoCargo() throws {
        let frame = try decode(#"{"type":"item","streamId":"s-1","value":null}"#)
        XCTAssertEqual(frame.value, .null)
        guard case .foreign(nil) = FollowItem.read(try XCTUnwrap(frame.value)) else {
            return XCTFail("null 里读不出 type，按 foreign 丢")
        }
    }

    // MARK: - 分支名（给上表一个可断言的标签）

    private static func followName(_ reading: CargoReading<FollowItem>) -> String {
        switch reading {
        case .decoded(.opening): return "follow.opening"
        case .decoded(.sessionEvent): return "follow.event"
        case .decoded(.transient): return "follow.transient"
        case .unparsable: return "unparsable"
        case .foreign: return "foreign"
        }
    }

    private static func eventsName(_ reading: CargoReading<EventsItem>) -> String {
        switch reading {
        case .decoded(.ready): return "events.ready"
        case .decoded(.emit): return "events.emit"
        case .decoded(.waterfall): return "events.waterfall"
        case .decoded(.cancel): return "events.cancel"
        case .unparsable: return "unparsable"
        case .foreign: return "foreign"
        }
    }

    private static func controlName(_ reading: CargoReading<ControlValue>) -> String {
        switch reading {
        case .decoded(.baseline): return "control.baseline"
        case .decoded(.projection): return "control.projection"
        case .unparsable: return "unparsable"
        case .foreign: return "foreign"
        }
    }
}
