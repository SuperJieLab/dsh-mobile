/**
 * 审批那条连接级流的判据 —— `ApprovalStreamReader` 与 `ApprovalStream`
 * （`Features/Approval/State/Stream/`）。
 *
 * 三件事各一组：**开流帧的字节**（网关按 op 分派，写错一个字母整条流开不起来）、
 * **判读的值域**（这条流只认三种 item，别的一律丢弃并留痕）、**收端的分派**
 * （代次与两类货物各到各的听众）。
 *
 * 判据的来历与列表那条流（`SessionListStreamTests`）相同：认的是网关的 item 形状，一份会
 * 漂移的东西，而认错了不会编译失败，也不会有哪条测试红。样本按「读得出 / 读不出」两侧各给几个。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ApprovalStreamTests: XCTestCase {

    private func read(_ text: String) throws -> ApprovalReading {
        let frame = try XCTUnwrap(InboundFrame.decode(Data(text.utf8)), "这一帧该解得开：\(text.prefix(80))")
        return ApprovalStreamReader.read(frame)
    }

    private func waterfall(eventId: String = "e1", session: String = "s1") -> JSONValue {
        .object([
            "kind": .string("waterfall"),
            "event": .string("approval/request"),
            "eventId": .string(eventId),
            "agentId": .string(session),
            "request": .object(["toolName": .string("bash")]),
        ])
    }

    // MARK: - 开流帧

    /// 这一条与 `MuxShapeTests` 的那条不重复：那边守「四种开流帧都编得对」的**形状**，
    /// 这条守「审批流用的是它自己那个工厂」—— 用一个 `op:"session-list"` 的工厂去开审批流，
    /// 形状全对而网关会把它当列表流，症状是审批卡永远不来。
    func testTheApprovalsStreamOpensWithItsOwnOp() throws {
        let text = try ApprovalStream().build("a1")
        XCTAssertEqual(text, #"{"payload":{"op":"approvals"},"streamId":"a1","type":"open"}"#)
    }

    func testTheLabelNamesThisStreamAndNotTheOldSharedOne() {
        XCTAssertEqual(ApprovalStream().label, "approvals",
                       "日志里认人的标识要与 op 一致；沿用旧名字会让三条流在日志里分不开")
    }

    // MARK: - 判读：这条流只认三种 item

    func testReadyCarriesTheGenerationAndAbsenceStaysNil() throws {
        let withGeneration = try read(#"{"type":"item","streamId":"a1","payload":{"kind":"ready","generation":3}}"#)
        guard case .ready(let generation) = withGeneration.content else {
            return XCTFail("带代次的 ready 该判成 ready，实际：\(withGeneration.content)")
        }
        XCTAssertEqual(generation, 3)

        let withoutGeneration = try read(#"{"type":"item","streamId":"a1","payload":{"kind":"ready"}}"#)
        guard case .ready(let absent) = withoutGeneration.content else {
            return XCTFail("不带代次的 ready 同样是 ready，实际：\(withoutGeneration.content)")
        }
        XCTAssertNil(absent, "代次缺席表示源此刻没有活的代次 —— 不猜 0")
    }

    /// 两种货物各自一个支，载荷原样：这一层不解释 `request` 里的字段。
    func testTheTwoCargoesBecomeTheirOwnBranches() throws {
        let pending = try read("""
        {"type":"item","streamId":"a1","payload":
          {"kind":"waterfall","event":"approval/request","eventId":"e1","agentId":"s1","request":{"toolName":"bash"}}}
        """)
        guard case .waterfall(let payload) = pending.content else {
            return XCTFail("waterfall 该判成 .waterfall，实际：\(pending.content)")
        }
        XCTAssertEqual(payload["eventId"]?.string, "e1")
        XCTAssertEqual(payload["kind"]?.string, "waterfall", "载荷原样，含 kind 自己")

        let cancelled = try read(#"{"type":"item","streamId":"a1","payload":{"kind":"cancel","eventId":"e1"}}"#)
        guard case .cancel(let body) = cancelled.content else {
            return XCTFail("cancel 该判成 .cancel，实际：\(cancelled.content)")
        }
        XCTAssertEqual(body["eventId"]?.string, "e1")
    }

    /// 别的流的货物落到这条流上 —— 一律丢弃。
    ///
    /// 这是拆流之后新增的那一半：以前同一条流上三种货物都合法，现在只有两种。网关按流
    /// 分派（判据在 `stream.split.test.ts` 的 U4），但客户端也要自己守住 —— 网关的错版本、
    /// 或者有人把泵改回去，症状会是「审批卡里混进一行会话」。
    func testCargoesFromOtherStreamsAreIgnored() throws {
        for kind in ["session-list", "emit"] {
            let reading = try read("""
            {"type":"item","streamId":"a1","payload":{"kind":"\(kind)","change":{"kind":"removed","id":"s1"}}}
            """)
            XCTAssertEqual(reading.content, .ignored, "\(kind) 不属于审批流")
            XCTAssertFalse(reading.establishes, "\(kind) 不建立这条流")
        }
    }

    func testRefusalKeepsCodeAndMessage() throws {
        let reading = try read(#"{"type":"error","streamId":"a1","payload":{"code":"source-unavailable","message":"not ready"}}"#)
        guard case .refused(let failure) = reading.content else {
            return XCTFail("error 帧该判成 refused，实际：\(reading.content)")
        }
        XCTAssertEqual(failure.code, GatewayErrorCode.sourceUnavailable.rawValue)
        XCTAssertEqual(failure.message, "not ready")
    }

    func testUnrecognizedShapesAreIgnoredRatherThanGuessed() throws {
        // 没有 kind 的 item、不认识的帧类型、坏 JSON 之上的空对象 —— 一律 ignored。
        XCTAssertEqual(try read(#"{"type":"item","streamId":"a1","payload":{"nokind":true}}"#).content, .ignored)
        XCTAssertEqual(try read(#"{"type":"nonsense","streamId":"a1"}"#).content, .ignored)
    }

    // MARK: - 流层要读的两格

    /// 只有 `ready` 建立这条流：`establish` 真时流层把退避归零。
    /// 货物若能建成，这条流会在源还没有代次时被当成开成了，于是开流超时撤防、退避归零。
    func testOnlyReadyEstablishesTheStream() throws {
        XCTAssertTrue(try read(#"{"type":"item","streamId":"a1","payload":{"kind":"ready"}}"#).establishes)
        XCTAssertFalse(try read(#"{"type":"item","streamId":"a1","payload":{"kind":"waterfall","eventId":"e1"}}"#).establishes)
        XCTAssertFalse(try read(#"{"type":"item","streamId":"a1","payload":{"kind":"cancel","eventId":"e1"}}"#).establishes)
    }

    /// 四种收场：正常收尾换号重开；可重试的拒绝按自己的退避重开；终态收起。
    func testTheNextActionFollowsWhetherARetryCanHelp() throws {
        XCTAssertEqual(try read(#"{"type":"end","streamId":"a1"}"#).next, .reopen)

        let retryable = try read(#"{"type":"error","streamId":"a1","payload":{"code":"source-unavailable","message":"x"}}"#)
        XCTAssertEqual(retryable.next, .retry, "源没就绪会变好 —— 值得再试")
        let internalError = try read(#"{"type":"error","streamId":"a1","payload":{"code":"internal-error","message":"x"}}"#)
        XCTAssertEqual(internalError.next, .retry)

        let unknownOp = try read(#"{"type":"error","streamId":"a1","payload":{"code":"unknown-op","message":"x"}}"#)
        XCTAssertEqual(unknownOp.next, .stop, "这台网关不认 approvals —— 再开一万次也一样")
    }

    // MARK: - 收端的分派

    /// 每一条 `ready` 都叫一次代次听众，**不比较新旧**：网关每次开流都发一条，
    /// 语义就是「从这一刻起你看到的都是新的」。失效那一次带 `nil`。
    func testGenerationListenersFirePerReadyIncludingSourceLoss() {
        let stream = ApprovalStream()
        var seen: [Int?] = []
        stream.onGeneration { seen.append($0) }

        stream.handle(ApprovalReading(content: .ready(generation: 5)))
        stream.handle(ApprovalReading(content: .ready(generation: 5)))
        stream.handle(ApprovalReading(content: .ready(generation: nil)))

        XCTAssertEqual(seen.count, 3, "同一个代次来两次也要叫两次 —— 每次 ready 都是一份新基线")
        XCTAssertNil(stream.generation, "最后一条 ready 不带代次 —— 值归 nil")
    }

    /// 两类货物各到各的听众，不串。
    func testEachCargoReachesItsOwnListener() {
        let stream = ApprovalStream()
        var pending: [JSONValue] = []
        var cancelled: [JSONValue] = []
        stream.onWaterfall { pending.append($0) }
        stream.onCancel { cancelled.append($0) }

        let one = waterfall(eventId: "e1")
        stream.handle(ApprovalReading(content: .waterfall(one)))
        stream.handle(ApprovalReading(content: .cancel(.object(["eventId": .string("e1")]))))

        XCTAssertEqual(pending, [one], "待答调用只到待答那个听众")
        XCTAssertEqual(cancelled, [.object(["eventId": .string("e1")])], "撤回只到撤回那个听众")
    }

    /// 退订按身份摘一个，不影响别的；摘两次不炸。
    func testUnsubscribingRemovesOnlyThatListener() {
        let stream = ApprovalStream()
        var first = 0
        var second = 0
        let offFirst = stream.onWaterfall { _ in first += 1 }
        stream.onWaterfall { _ in second += 1 }

        stream.handle(ApprovalReading(content: .waterfall(waterfall())))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)

        offFirst()
        offFirst()
        stream.handle(ApprovalReading(content: .waterfall(waterfall())))
        XCTAssertEqual(first, 1, "摘下之后不再收")
        XCTAssertEqual(second, 2, "另一个听众不受影响")
    }
}
