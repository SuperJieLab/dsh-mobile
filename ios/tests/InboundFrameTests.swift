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

    func testUsageFrameCarriesTheSnapshot() throws {
        let frame = try decode(#"{"type":"usage","streamId":"s-1","payload":{"sessionId":"s-1","asOfSeq":5}}"#)

        guard case .usage(let payload) = frame.payload else {
            return XCTFail("usage 帧该归 usage，实际：\(String(describing: frame.payload))")
        }
        // 会话归属跟着快照一起出来：判读层靠它决定画不画（帧串流时会收到别人的占用）。
        XCTAssertEqual(payload.sessionId, "s-1")
        XCTAssertEqual(payload.snapshot.asOfSeq, 5)
    }

    // MARK: - 认不出的载荷

    /// 四条「认不出」：缺三个字段、空对象、只有 type 没有 seq、未知 type。
    /// 它们共用一条判据：**载荷解不出来 → `nil`**，而不是让整帧解码失败。
    func testUnrecognizedItemPayloadsBecomeNil() throws {
        let cases: [(name: String, payload: String)] = [
            ("空对象", "{}"),
            ("只有 type", #"{"type":"odd"}"#),
            ("未知 type", #"{"type":"future-thing","data":{}}"#),
            ("缺 events", #"{"sessionId":"s-1","cursor":1}"#),
        ]

        for item in cases {
            let text = #"{"type":"item","streamId":"s-1","payload":\#(item.payload)}"#
            let frame = try decode(text)
            XCTAssertNil(frame.payload, "「\(item.name)」该是 nil，实际：\(String(describing: frame.payload))")
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
}
