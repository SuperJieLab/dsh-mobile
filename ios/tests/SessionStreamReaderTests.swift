/**
 * 帧判读的判据 —— `SessionStreamReader`（`SessionDetail/State/SessionStreamReader.swift`）。
 *
 * 这一组测的事只有一件：**给一段帧文本与所属会话，判成什么、这条流接下来怎么办**。
 * 全部不需要连接、不需要网络 —— 判读认的是上游的事件形状，一份会漂移的东西，它的错既不会
 * 编译失败也不会有哪条测试红，除非它自己有一条断言。
 *
 * 分类口径来自两端协定的订阅流一节；七类各有样本，坏帧有容错样本。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionStreamReaderTests: XCTestCase {

    private func read(_ text: String, session: String = "s-1") throws -> StreamReading {
        let data = Data(text.utf8)
        let envelope = try JSONDecoder().decode(MuxServerEnvelope.self, from: data)
        return SessionStreamReader.read(envelope: envelope, raw: data, sessionId: session)
    }

    private func envelope(_ text: String) throws -> MuxServerEnvelope {
        try JSONDecoder().decode(MuxServerEnvelope.self, from: Data(text.utf8))
    }

    // MARK: - O1：打开帧（三字段同在）

    /// 三个字段同在才进这一支；缺任何一个都该落到别的分类里去（`MuxShapeTests` 守着
    /// 缺字段那三条，这里守正向样本本身没被判歪）。
    func testOpeningNeedsAllThreeFields() throws {
        let reading = try read("""
        {"type":"item","streamId":1,"payload":{
          "sessionId":"s-1","pageStart":2,"cursor":5,"hasOlder":true,
          "events":[{"type":"user/message","seq":2,"time":1700000000000,"data":{}}]}}
        """)

        guard case .opening(let opening) = reading.content else {
            return XCTFail("三字段同在该判成打开帧，实际：\(reading.content)")
        }
        XCTAssertEqual(opening.cursor, 5, "窗口末尾取 cursor")
        XCTAssertEqual(opening.events.map(\.seq), [2], "事件照常带出")
    }

    // MARK: - O2：事件帧（type + seq）

    /// 载荷本体就是一条事件 —— 判读只负责认出它，值靠直解一次拿到。
    func testEventFrameCarriesTheEvent() throws {
        let reading = try read("""
        {"type":"item","streamId":1,"payload":
          {"type":"user/message","seq":7,"time":1700000000000,"data":{}}}
        """)

        guard case .event(let event) = reading.content else {
            return XCTFail("带 type 与 seq 的载荷该判成事件帧，实际：\(reading.content)")
        }
        XCTAssertEqual(event.type, "user/message")
        XCTAssertEqual(event.seq, 7)
    }

    // MARK: - O3：未定稿帧

    /// 未定稿帧带 `type` 但不带 `seq` —— 判据的顺序必须让它排在事件帧之前，否则它会被
    /// 当成事件帧丢掉（事件解码失败即 `.ignored`），屏幕上「正在生成」那一段就永远不出现。
    func testTransientFrameKeepsItsInnerFrame() throws {
        let reading = try read("""
        {"type":"item","streamId":1,"payload":
          {"type":"assistant-stream","frame":{"type":"chunk","revision":3,"index":2}}}
        """)

        guard case .transient(let frame) = reading.content else {
            return XCTFail("assistant-stream 该判成未定稿帧，实际：\(reading.content)")
        }
        XCTAssertEqual(frame["type"]?.string, "chunk", "内层 frame 原样转出")
        XCTAssertEqual(frame["index"]?.int, 2)
    }

    // MARK: - O4：占用读数（核会话归属）

    /// 帧串流时不能画别人的占用 —— 会话对不上就丢弃，而不是画出来。
    func testUsageOnlyCountsForItsOwnSession() throws {
        let own = try read("""
        {"type":"usage","streamId":1,"payload":{"sessionId":"s-1","asOfSeq":5}}
        """)
        guard case .usage(let snapshot) = own.content else {
            return XCTFail("本流的占用读数该判成 usage，实际：\(own.content)")
        }
        XCTAssertEqual(snapshot.asOfSeq, 5)

        let other = try read("""
        {"type":"usage","streamId":1,"payload":{"sessionId":"s-2","asOfSeq":5}}
        """)
        guard case .ignored = other.content else {
            return XCTFail("别的会话的占用读数必须丢弃，实际：\(other.content)")
        }
    }

    // MARK: - O5：拒绝帧

    /// 码与原文都要带出来：码决定「值不值得重连」，原文是用户能看懂的那句。
    func testRefusalKeepsCodeAndMessage() throws {
        let reading = try read("""
        {"type":"error","streamId":1,"payload":{"code":"window-too-large","message":"窗口太大"}}
        """)

        guard case .refused(let failure) = reading.content else {
            return XCTFail("error 帧该判成拒绝，实际：\(reading.content)")
        }
        XCTAssertEqual(failure.code, "window-too-large")
        XCTAssertEqual(failure.message, "窗口太大")
    }

    // MARK: - O6：收尾帧

    /// 收尾 = 这条流还在、但不在工作了 ⇒ 重开一次（连接不重建）。
    func testEndMeansReopen() throws {
        let reading = try read(#"{"type":"end","streamId":1}"#)

        guard case .ended = reading.content else {
            return XCTFail("end 帧该判成收尾，实际：\(reading.content)")
        }
        XCTAssertEqual(reading.next, .reopen, "收尾之后要在同一条连接上重开")
    }

    // MARK: - O7：审批帧（没有流编号）

    /// 审批帧是连接级的：它没有 `streamId`。外壳把它解成 `nil`，判读照样认得出载荷。
    func testApprovalFrameHasNoStreamId() throws {
        let text = #"{"type":"approval","payload":{"kind":"request","callId":"c1"}}"#
        let reading = try read(text)

        guard case .approval(let payload) = reading.content else {
            return XCTFail("approval 帧该判成审批，实际：\(reading.content)")
        }
        XCTAssertEqual(payload["kind"]?.string, "request")
        XCTAssertNil(try envelope(text).streamId, "审批帧没有流编号 —— 它不是哪条流的一部分")
    }

    // MARK: - O8：认不出的

    /// 三条「认不出」：未知类型、`item` 但缺载荷、`item` 带着 `type` 却既不是未定稿也不是事件
    /// （没有 `seq`）。一律 `.ignored` —— 丢弃，不重试也不猜。
    func testUnrecognizedFramesAreIgnored() throws {
        let cases: [(name: String, text: String)] = [
            ("未知类型", #"{"type":"future-thing","streamId":1,"payload":{}}"#),
            ("item 缺载荷", #"{"type":"item","streamId":1}"#),
            ("item 带 type 却没有 seq", #"{"type":"item","streamId":1,"payload":{"type":"odd"}}"#),
            ("item 的载荷是空对象", #"{"type":"item","streamId":1,"payload":{}}"#),
        ]

        for item in cases {
            let reading = try read(item.text)
            guard case .ignored = reading.content else {
                return XCTFail("「\(item.name)」该被丢弃，实际：\(reading.content)")
            }
            XCTAssertEqual(reading.next, .keep, "「\(item.name)」不该让这条流改变动作")
        }
    }

    // MARK: - O9：「建成」只在打开帧上成立

    /// 建成判据的落点。写成「收到任何一帧即建成」的版本会让心跳提前激活 —— 审批对账帧先到、
    /// 打开帧还在路上时，连接会在几拍之后被判死（`livenessTick` 的注释里记着这条现场）。
    func testOnlyAnOpeningEstablishesTheStream() throws {
        let samples: [(name: String, text: String, establishes: Bool)] = [
            ("打开帧", #"{"type":"item","streamId":1,"payload":{"sessionId":"s-1","cursor":1,"events":[]}}"#, true),
            ("事件帧", #"{"type":"item","streamId":1,"payload":{"type":"user/message","seq":1,"time":1,"data":{}}}"#, false),
            ("审批帧", #"{"type":"approval","payload":{"kind":"request"}}"#, false),
            ("占用帧", #"{"type":"usage","streamId":1,"payload":{"sessionId":"s-1","asOfSeq":1}}"#, false),
            ("收尾帧", #"{"type":"end","streamId":1}"#, false),
            ("拒绝帧", #"{"type":"error","streamId":1,"payload":{"code":"internal-error","message":""}}"#, false),
        ]

        for sample in samples {
            let reading = try read(sample.text)
            XCTAssertEqual(reading.establishes, sample.establishes,
                           "「\(sample.name)」的建成判定不对")
        }
    }

    // MARK: - O10：这条流接下来怎么办

    /// 四种动作各有归属：收尾重开、终态停、其余拒绝重连、其他什么都不做。
    func testNextActionOfEachKind() throws {
        let reopen = try read(#"{"type":"end","streamId":1}"#)
        XCTAssertEqual(reopen.next, .reopen)

        for code in ["unknown-session", "unreadable-session", "window-too-large"] {
            let reading = try read("""
            {"type":"error","streamId":1,"payload":{"code":"\(code)","message":""}}
            """)
            XCTAssertEqual(reading.next, .stop, "\(code) 是会话级终态 —— 重连只会再收一次")
        }

        let retryable = try read(#"{"type":"error","streamId":1,"payload":{"code":"internal-error","message":""}}"#)
        XCTAssertEqual(retryable.next, .reconnect, "非终态的拒绝要退避重连")

        let opening = try read(#"{"type":"item","streamId":1,"payload":{"sessionId":"s-1","cursor":1,"events":[]}}"#)
        XCTAssertEqual(opening.next, .keep, "打开帧之后什么都不用做")
    }

    // MARK: - O11：未知码按可重试

    /// 白名单之外的码不该让会话卡死：宁可多连几次（屏幕上看得见「重连中」），
    /// 也不要静默挂死。
    func testAnUnknownCodeIsRetried() throws {
        let reading = try read(#"{"type":"error","streamId":1,"payload":{"code":"some-future-code","message":""}}"#)

        XCTAssertEqual(reading.next, .reconnect)
    }
}
