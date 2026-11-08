/**
 * 入站帧形状的判据 —— `InboundFrame`（`LongConnection/Wire/MuxFrames.swift`）。
 *
 * 这一组测的事只有一件：**一段线上文本，外壳与载荷各被认成什么**。
 * 它是「一帧只解析一次」的落点：分派靠 key 存在性，不被认出的形状落到 `nil`，
 * 判读层再把它归成 `.ignored`。
 *
 * 顺序也是契约：同一帧同时满足两条判据时，取表里靠前的那一条。改了顺序不会编译失败，
 * 只会让某一类帧悄悄换支 —— 所以第 8 条把它钉住。
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

    /// O1：三字段同在 → 打开帧，载荷直解成强类型。
    func testOpeningPayloadIsStronglyTyped() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","payload":{
          "sessionId":"s-1","pageStart":2,"cursor":5,"hasOlder":true,
          "events":[{"type":"user/message","seq":2,"time":1700000000000,"data":{}}]}}
        """)

        guard case .item(.opening(let payload)) = frame.payload else {
            return XCTFail("三字段同在该归 opening，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(payload.cursor, 5)
        XCTAssertEqual(payload.events?.compactMap(\.value).map(\.seq), [2])
    }

    /// O2：`type` + `seq` → 事件帧，本体直接是 `SessionEvent`。
    func testEventPayloadIsStronglyTyped() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","payload":
          {"type":"user/message","seq":7,"time":1700000000000,"data":{}}}
        """)

        guard case .item(.sessionEvent(let event)) = frame.payload else {
            return XCTFail("type+seq 该归 sessionEvent，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(event.type, "user/message")
        XCTAssertEqual(event.seq, 7)
    }

    /// O3：`assistant-stream` 不带 `seq`，且必须排在事件帧之前被认出来。
    func testTransientPayloadKeepsItsInnerFrame() throws {
        let frame = try decode("""
        {"type":"item","streamId":"s-1","payload":
          {"type":"assistant-stream","frame":{"type":"chunk","revision":3,"index":2}}}
        """)

        guard case .item(.transient(let inner)) = frame.payload else {
            return XCTFail("assistant-stream 该归 transient，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(inner["type"]?.string, "chunk")
        XCTAssertEqual(inner["index"]?.int, 2)
    }

    /// 事件流的货物：带 `kind`，整份载荷原样保留（消费方要的就是任意形状）。
    func testConnectionItemKeepsTheWholePayload() throws {
        let frame = try decode("""
        {"type":"item","streamId":"e-1","payload":{"kind":"ready","generation":3}}
        """)

        guard case .item(.connectionItem(let payload)) = frame.payload else {
            return XCTFail("带 kind 的该归 connectionItem，实际：\(String(describing: frame.payload))")
        }
        XCTAssertEqual(payload["kind"]?.string, "ready")
        XCTAssertEqual(payload["generation"]?.int, 3)
    }

    // MARK: - 非 item 外壳

    func testErrorFrameIsRefused() throws {
        let frame = try decode("""
        {"type":"error","streamId":"s-1","payload":{"code":"window-too-large","message":"窗口太大"}}
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

    // MARK: - 顺序契约

    /// `kind` 排在 `type`+`seq` 之前。事件流的货物可能同时带这两组 key，
    /// 顺序反了它就会被当成一条会话事件去解，然后失败成 `.ignored` —— 屏幕上永远等不到 `ready`。
    func testKindWinsOverEventShape() throws {
        let frame = try decode("""
        {"type":"item","streamId":"e-1","payload":{"kind":"emit","event":"x","type":"odd","seq":9}}
        """)

        guard case .item(.connectionItem) = frame.payload else {
            return XCTFail("kind 与 type+seq 同时存在时该归 connectionItem，实际：\(String(describing: frame.payload))")
        }
    }
}
