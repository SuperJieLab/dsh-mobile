/**
 * 线上形状的编解码判据 —— 帧外壳、开流请求、opening 三件（`LongConnection/Wire/MuxFrames.swift`）。
 *
 * 这几条测的都是「形状的语义在同一条线上没变」：
 * - U1 编码由形状决定，且确定（同一输入两次编码逐字相同）；
 * - U2 语义与改造前的字典字面量相同（解析成对象后 `isEqual`）—— 这是「线上请求没变」的判据；
 * - U3 四条样本帧的判读边界与改造前一致（坏事件单条跳过、缺字段的默认值、未知字段不失败）；
 * - O2 窗口投影不是逐字段复制：`asOfSeq` 取的是 `cursor`，不是 `pageStart`。
 */
import Foundation
import XCTest

@testable import DshMobile

final class MuxShapeTests: XCTestCase {

    // MARK: - U1：开流请求的字节由形状决定，且确定

    /// 同一份输入编出来的就是这一个字符串。
    ///
    /// 键序被 `.sortedKeys` 钉住，所以字面量可以直接断言 —— 不排序的字典编码键序随哈希
    /// （同一进程内连编 5 次会得到不同的几种顺序），那种写法下「两次编码相同」根本不成立。
    func testOpenFrameEncodingIsTheDeclaredBytes() throws {
        let text = try MuxOpenFrame.following(sessionId: "s-1", streamId: "s-9").encoded()

        XCTAssertEqual(text,
                       #"{"payload":{"op":"follow","sessionId":"s-1"},"streamId":"s-9","type":"open"}"#,
                       "开流帧的字节与形状声明不一致 —— 字段名或外壳三层被改动过")
    }

    /// 确定性的那一半：每次重新构造、重新编码，5 次得到同一个字符串。
    ///
    /// 用新实例而不是同一实例编 5 次：编码器状态、哈希种子若参与键序，只有重新构造才看得见。
    func testOpenFrameEncodingIsStableAcrossRuns() throws {
        let texts = try (1...5).map { _ in
            try MuxOpenFrame.following(sessionId: "s-1", streamId: "s-9").encoded()
        }

        XCTAssertEqual(Set(texts).count, 1,
                       "同一份输入编出了 \(Set(texts).count) 种字节 —— 键序没有钉住")
    }

    // MARK: - O1：取消帧是独立的线上形状

    /// 关一条流有自己的帧：`{"streamId":"…","type":"cancel"}`，键序同样被钉住。
    ///
    /// 这一条证明的是「取消不是关连接」在协议上的那一半：帧里只有一个编号，没有任何
    /// 连接级字段 —— 网关收到它只停那一条泵。
    func testCancelFrameEncodingIsTheDeclaredBytes() throws {
        XCTAssertEqual(try MuxCancelFrame(streamId: "s-9").encoded(),
                       #"{"streamId":"s-9","type":"cancel"}"#,
                       "取消帧的字节与形状声明不一致")

        // 与打开帧同一条纪律：重新构造 5 次，字节不变。
        let texts = try (1...5).map { _ in try MuxCancelFrame(streamId: "s-9").encoded() }
        XCTAssertEqual(Set(texts).count, 1, "同一份输入编出了多种字节 —— 键序没有钉住")
    }

    /// 两种帧的编号都是**字符串** —— 与网关 `wire/mux.ts` 的 `StreamId` 同形。
    ///
    /// 这条防的是「编号又变回数字」：数字会让它重新变得可解释（「1 是会话流」），
    /// 而复用编号正是本期拆掉的那个假设。
    func testStreamIdIsAStringOnTheWire() throws {
        let open = try JSONSerialization.jsonObject(
            with: Data(try MuxOpenFrame.following(sessionId: "s-1", streamId: "s-9").encoded().utf8)
        ) as? [String: Any]
        XCTAssertTrue(open?["streamId"] is String, "开流帧的编号必须是字符串")

        let cancel = try JSONSerialization.jsonObject(
            with: Data(try MuxCancelFrame(streamId: "s-9").encoded().utf8)
        ) as? [String: Any]
        XCTAssertTrue(cancel?["streamId"] is String, "取消帧的编号必须是字符串")
    }

    // MARK: - U2：线上语义与字典字面量那一版相同

    /// 线上对象逐字段相同 —— 比的是**解析后的对象**，不是字节。
    ///
    /// 基线特意写成与 U1 字面量**不同的键序**（`streamId` 在前）：这样这一条同时证明两件事 ——
    /// 字段名 / 值 / 类型没变，且键序不参与比较。若基线照抄实现的输出，它就只剩「和自己是
    /// 自己」这一句。
    func testOpenFrameKeepsTheWireObjectOfTheDictionaryLiteral() throws {
        let baseline = #"{"streamId":"s-9","payload":{"sessionId":"s-1","op":"follow"},"type":"open"}"#

        let baselineObject = try JSONSerialization.jsonObject(with: Data(baseline.utf8))
        let encoded = try MuxOpenFrame.following(sessionId: "s-1", streamId: "s-9").encoded()
        let newObject = try JSONSerialization.jsonObject(with: Data(encoded.utf8))

        XCTAssertTrue((baselineObject as? NSDictionary)?.isEqual(newObject) == true,
                      "开流请求的线上对象变了 —— 网关按名取字段，这一条红了就是真的改了协议")
    }

    // MARK: - U3：opening 的判读边界与改造前一致

    private func frame(_ payload: String) -> Data {
        Data(#"{"type":"item","streamId":"s-1","payload":\#(payload)}"#.utf8)
    }

    func testOpeningDecodesTheFullSample() throws {
        let data = frame("""
        {"sessionId":"s-1","pageStart":2,"cursor":5,"hasOlder":true,
         "events":[
           {"type":"user/message","seq":2,"time":1700000000000,"data":{}},
           {"type":"assistant/message","seq":5,"time":1700000000001,"data":{}}
         ]}
        """)

        let opening = try XCTUnwrap(OpeningFrame.decode(data), "正常样本解不出来")

        XCTAssertEqual(opening.sessionId, "s-1")
        XCTAssertEqual(opening.pageStart, 2)
        XCTAssertEqual(opening.cursor, 5)
        XCTAssertTrue(opening.hasOlder)
        XCTAssertEqual(opening.events.map(\.seq), [2, 5], "好事件保序保留")
    }

    func testOpeningSkipsOnlyTheBadEvent() throws {
        let data = frame("""
        {"sessionId":"s-1","cursor":3,"pageStart":0,"hasOlder":true,
         "events":[
           {"type":"user/message","seq":1,"time":1700000000000,"data":{}},
           {"type":"user/message","seq":"oops","time":1700000000001,"data":{}},
           {"type":"assistant/message","seq":2,"time":1700000000002,"data":{}}
         ]}
        """)

        let opening = try XCTUnwrap(OpeningFrame.decode(data), "坏事件不该让整帧解不出来")

        XCTAssertEqual(opening.events.map(\.seq), [1, 2], "坏事件单条跳过，其余照常")
    }

    /// 缺 `cursor` / `sessionId` / `events` 任一 ⇒ 判不出这是 opening，返回 nil。
    /// 判读方据此走「等下一帧 / 开流超时」。
    ///
    /// 三个字段分开断言：它们是同一个 `guard` 的三段，而「只写了第一段」的写法在别的两支上
    /// 会静默放过 —— 一条事件帧于是被当成 opening、把窗口清空。
    func testOpeningWithoutItsRequiredFieldsIsNotAnOpening() {
        let cases: [(name: String, payload: String)] = [
            ("cursor", #"{"sessionId":"s-1","pageStart":0,"events":[]}"#),
            ("sessionId", #"{"pageStart":0,"cursor":2,"events":[]}"#),
            ("events", #"{"sessionId":"s-1","pageStart":0,"cursor":2}"#),
        ]

        for item in cases {
            XCTAssertNil(OpeningFrame.decode(frame(item.payload)),
                         "缺 \(item.name) 仍被判成 opening —— 路由判据被放宽了")
        }
    }

    /// 未知字段不导致失败；缺 `pageStart` / `hasOlder` 落到默认值 `0` / `false`。
    ///
    /// 网关加字段是常态（协议承诺事件体原样透传），而这两个默认值正是改造前 `?? 0` / `?? false`
    /// 的口径。
    func testOpeningToleratesUnknownFieldsAndDefaultsMissingOnes() throws {
        let data = frame("""
        {"sessionId":"s-1","cursor":4,"debugTrace":{"hop":"relay"},"events":[]}
        """)

        let opening = try XCTUnwrap(OpeningFrame.decode(data), "多一个未知字段就整帧失败")

        XCTAssertEqual(opening.pageStart, 0, "缺 pageStart 应为 0")
        XCTAssertFalse(opening.hasOlder, "缺 hasOlder 应为 false")
        XCTAssertEqual(opening.cursor, 4)
    }

    // MARK: - O2：窗口投影不是逐字段复制

    /// `pageStart` 与 `cursor` 取不同的值，`asOfSeq` 必须等于 `cursor`。
    ///
    /// 两者相等时，写错成 `pageStart` 也看不出来 —— 样本的边界值决定哪一支被漏掉。
    func testPageProjectsTheOpeningCursorOntoAsOfSeq() throws {
        let data = frame("""
        {"sessionId":"s-1","pageStart":3,"cursor":9,"hasOlder":true,
         "events":[{"type":"user/message","seq":7,"time":1700000000000,"data":{}}]}
        """)
        let opening = try XCTUnwrap(OpeningFrame.decode(data))

        let page = SessionPage(opening: opening)

        XCTAssertEqual(page.asOfSeq, 9, "asOfSeq 应取 cursor（窗口末尾），不是 pageStart")
        XCTAssertEqual(page.pageStart, 3, "pageStart 直传")
        XCTAssertTrue(page.hasOlder, "hasOlder 直传")
        XCTAssertEqual(page.events.map(\.seq), [7], "events 直传")
    }

    // MARK: - O8：第二类开流帧（连接级事件流）

    /// 事件流的开流帧：外壳与 follow 那一套完全相同，载荷只有 `op`。
    ///
    /// 网关侧的分派靠两段 —— 信封读编号、`openRequestOf` 读 `op`（`wire/mux.ts`）。所以这一帧
    /// 多一个字段（比如顺手带上 `sessionId`）虽不会被拒，却会让两端对「这条流绑不绑会话」的
    /// 理解分岔；少写 `type` 则连信封都读不出，整条连接会被关。
    func testEventsOpenFrameIsTheDeclaredBytes() throws {
        XCTAssertEqual(try MuxOpenFrame.events(streamId: "e1").encoded(),
                       #"{"payload":{"op":"events"},"streamId":"e1","type":"open"}"#,
                       "事件流开流帧的字节与形状声明不一致 —— 字段名或外壳被改动过")
    }

    /// 确定性的那一半：重新构造、重新编码，5 次得到同一个字符串。
    ///
    /// 与 follow 同一条纪律（`.sortedKeys`），但它是**第二份**独立验证：两个工厂各自走
    /// `muxText(of:)`，哪一天有人在 `events` 那条路上绕开它自己拼 JSON，这一条先红。
    func testEventsOpenFrameEncodingIsStableAcrossRuns() throws {
        let texts = try (1...5).map { _ in
            try MuxOpenFrame.events(streamId: "e1").encoded()
        }

        XCTAssertEqual(Set(texts).count, 1,
                       "同一份输入编出了 \(Set(texts).count) 种字节 —— 键序没有钉住")
    }
}
