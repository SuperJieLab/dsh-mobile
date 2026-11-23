/**
 * 线上形状的编解码判据 —— 帧外壳、开流请求、opening 三件（`LongConnection/Wire/MuxFrames.swift`）。
 *
 * 这几条测的都是「形状的语义在同一条线上没变」：
 * - U1 编码由形状决定，且确定（同一输入两次编码逐字相同）；
 * - U2 语义与改造前的字典字面量相同（解析成对象后 `isEqual`）—— 这是「线上请求没变」的判据；
 * - U3 四条样本帧的判读边界与改造前一致（坏事件单条跳过、缺字段的默认值、未知字段不失败）；
 * - O2 窗口起点由首条记录给出，切点原样（含端）。
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
    ///
    /// 第 2 期起 `args` 里套一层 `request`（宿主的形参名），窗口参数由客户端给全 ——
    /// 网关不再替我们换算，所以这四个数就是上游 `HISTORY_PAGE_OPTIONS` 那一组。
    func testOpenFrameEncodingIsTheDeclaredBytes() throws {
        let text = try MuxOpenFrame.following(sessionId: "s-1", streamId: "s-9").encoded()

        XCTAssertEqual(text,
                       #"{"endpoint":"session/follow","payload":{"args":{"request":{"activate":true,"address":{"kind":"session","sessionId":"s-1"},"assistantStream":true,"maxMessages":500,"turnWindow":{"minMessages":50,"minTurns":2}}}},"streamId":"s-9","type":"open"}"#,
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
        let baseline = #"{"streamId":"s-9","endpoint":"session/follow","payload":{"args":{"request":{"activate":true,"address":{"kind":"session","sessionId":"s-1"},"assistantStream":true,"maxMessages":500,"turnWindow":{"minMessages":50,"minTurns":2}}}},"type":"open"}"#

        let baselineObject = try JSONSerialization.jsonObject(with: Data(baseline.utf8))
        let encoded = try MuxOpenFrame.following(sessionId: "s-1", streamId: "s-9").encoded()
        let newObject = try JSONSerialization.jsonObject(with: Data(encoded.utf8))

        XCTAssertTrue((baselineObject as? NSDictionary)?.isEqual(newObject) == true,
                      "开流请求的线上对象变了 —— 网关按名取字段，这一条红了就是真的改了协议")
    }

    // MARK: - U3：opening 的判读边界（五格必填）

    /// 把一段**不含 `type`** 的打开帧载荷包成 item 帧：`value` 里补上 `snapshot` 判别字段。
    /// `dropFirst()` 去掉调用方写的前导 `{`，补回去的是一整段 `{"type":"snapshot", …}`。
    private func frame(_ payload: String) -> Data {
        Data(#"{"type":"item","streamId":"s-1","value":{"type":"snapshot",\#(payload.dropFirst())}"#.utf8)
    }

    /// 走产品实际走的那条路：外壳解一次，货物由 `session/follow` 自己解，再成形。
    ///
    /// 不直接按类型解码 —— 那两跳（外壳 → 本流的货物）正是「一帧只解析一次」与
    /// 「按流解货物」的落点，判据绕开它们就守不住「五格同在才归 opening」这件事。
    private func decodeOpening(_ data: Data) -> SnapshotFrame? {
        guard let frame = InboundFrame.decode(data),
              let value = frame.value,
              case .decoded(.opening(let shape)) = FollowItem.read(value) else { return nil }
        return shape.frame()
    }

    /// 五格都在时的完整样本：头部、**含端**的 `cursor`、记录（事件在 `event` 那一格里）、
    /// `hasMore`、投影基线。
    func testOpeningDecodesTheFullSample() throws {
        let data = frame("""
        {"header":{"version":1,"id":"s-1","createdAt":1700000000000,"cwd":"/tmp/x","isSeeded":false},
         "cursor":5,"hasMore":true,
         "records":[
           {"type":"event","event":{"type":"user/message","seq":2,"time":1700000000000,"data":{}}},
           {"type":"event","event":{"type":"assistant/message","seq":5,"time":1700000000001,"data":{}}}
         ],
         "projections":{"asOfSeq":5,"values":{"title":"t"}}}
        """)

        let opening = try XCTUnwrap(decodeOpening(data), "正常样本解不出来")

        XCTAssertEqual(opening.header.id, "s-1", "会话 id 在头部（从前那一格叫 sessionId）")
        XCTAssertFalse(opening.header.isSeeded)
        XCTAssertEqual(opening.cursor, 5, "cursor 是宿主给的含端上界，原样")
        XCTAssertTrue(opening.hasMore)
        XCTAssertEqual(opening.records.map(\.event.seq), [2, 5], "记录保序，事件在 `event` 那一格里")
        XCTAssertEqual(opening.records.map(\.type), ["event", "event"], "判别字段原样保留")
        XCTAssertEqual(opening.projections.asOfSeq, 5)
    }

    /// 一条记录坏了只丢那一条 —— 那一格解不出的是一条事件，不是整帧。
    func testOpeningSkipsOnlyTheBadRecord() throws {
        let data = frame("""
        {"header":{"version":1,"id":"s-1","createdAt":1700000000000,"isSeeded":false},
         "cursor":3,"hasMore":false,
         "records":[
           {"type":"event","event":{"type":"user/message","seq":1,"time":1700000000000,"data":{}}},
           {"type":"event","event":{"type":"user/message","seq":"oops","time":1700000000001,"data":{}}},
           {"type":"event","event":{"type":"assistant/message","seq":2,"time":1700000000002,"data":{}}}
         ],
         "projections":{"asOfSeq":3,"values":{}}}
        """)

        let opening = try XCTUnwrap(decodeOpening(data), "坏记录不该让整帧解不出来")

        XCTAssertEqual(opening.records.map(\.event.seq), [1, 2], "坏的那条跳过，其余照常")
    }

    /// 五格必填：缺任何一格都不是 opening，返回 nil，判读方据此走「等下一帧 / 开流超时」。
    ///
    /// 五格分开断言：它们是同一个 `guard` 的五段，只写第一段的写法在其余四支上会静默放过 ——
    /// **不补默认值**的理由在每一格上不同，而每一种「补」都不报错：
    /// `cursor` 补 0 是「日志是空的」、`hasMore` 补 false 是「上面没有了」（往回翻的入口
    /// 永远不出现）、`projections` 补空是「没有占用」。
    func testOpeningWithoutItsRequiredFieldsIsNotAnOpening() {
        let header = #""header":{"version":1,"id":"s-1","createdAt":1,"isSeeded":false}"#
        let records = #""records":[]"#
        let projections = #""projections":{"asOfSeq":0,"values":{}}"#
        let cases: [(name: String, payload: String)] = [
            ("header", "{\"cursor\":2,\"hasMore\":false,\"records\":[],\"projections\":{\"asOfSeq\":0,\"values\":{}}}"),
            ("cursor", "{\(header),\"hasMore\":false,\"records\":[],\"projections\":{\"asOfSeq\":0,\"values\":{}}}"),
            ("records", "{\(header),\"cursor\":2,\"hasMore\":false,\"projections\":{\"asOfSeq\":0,\"values\":{}}}"),
            ("hasMore", "{\(header),\"cursor\":2,\"records\":[],\"projections\":{\"asOfSeq\":0,\"values\":{}}}"),
            ("projections", "{\(header),\"cursor\":2,\"hasMore\":false,\"records\":[]}"),
        ]

        for item in cases {
            XCTAssertNil(decodeOpening(frame(item.payload)),
                         "缺 \(item.name) 仍被判成 opening —— 那一格被补了默认值或者判据被放宽了")
        }
    }

    /// 未知字段不导致失败：网关多给一格是常态（上游加字段时要能过），
    /// 但**必填格的缺席不因为多给了字段就变成合法**。
    func testOpeningToleratesUnknownFields() throws {
        let data = frame("""
        {"header":{"version":1,"id":"s-1","createdAt":1700000000000,"isSeeded":false,"debugTrace":1},
         "cursor":4,"hasMore":false,"records":[],
         "projections":{"asOfSeq":4,"values":{}},"debugTrace":{"hop":"relay"}}
        """)

        let opening = try XCTUnwrap(decodeOpening(data), "多一个未知字段就整帧失败")

        XCTAssertEqual(opening.cursor, 4)
        XCTAssertFalse(opening.hasMore)
    }

    /// 投影坏了不是「丢一格」：它是必填格，整帧丢弃。补一个空投影等于替服务端声明
    /// 「此刻没有占用」—— 而占用量正是这个格子唯一的用处，错了不会报错，只会画出 0。
    func testABrokenProjectionIsNotGuessed() {
        let data = frame("""
        {"header":{"version":1,"id":"s-1","createdAt":1700000000000,"isSeeded":false},
         "cursor":5,"hasMore":true,"records":[],
         "projections":{"asOfSeq":"oops"}}
        """)

        XCTAssertNil(decodeOpening(data), "坏的必填格不能被当成「那一格不在」放过去")
    }

    // MARK: - O2：窗口投影不是逐字段复制

    /// 打开帧就是第一屏：三个字段一一对应，窗口起点由首条记录**算出来**而不是由服务端给。
    ///
    /// 样本里 `cursor`（9）与首条记录的 `seq`（7）取不同的值 —— 两者相等时，
    /// 「起点取错了字段」这条写错也看不出来。
    func testTheOpeningBecomesTheFirstWindow() throws {
        let data = frame("""
        {"header":{"version":1,"id":"s-1","createdAt":1700000000000,"isSeeded":false},
         "cursor":9,"hasMore":true,
         "records":[{"type":"event","event":{"type":"user/message","seq":7,"time":1700000000000,"data":{}}}],
         "projections":{"asOfSeq":9,"values":{}}}
        """)
        let opening = try XCTUnwrap(decodeOpening(data))

        let window = SessionWindow(opening: opening)

        XCTAssertEqual(window.cursor, 9, "含端切点原样——换算成「下一个期望」是镜像入口的事")
        XCTAssertEqual(window.start, 7, "窗口起点是首条记录的 seq")
        XCTAssertTrue(window.hasMore, "hasMore 直传")
        XCTAssertEqual(window.events.map(\.seq), [7], "records 剥层成事件")
    }
}
