/**
 * 列表那条连接级流的判据 —— `SessionListStreamReader` 与 `SessionListStream`
 * （`Features/SessionList/State/Stream/`）。
 *
 * 与 `ApprovalStreamTests` 对称：开流帧的字节、判读的值域、收端的分派各一组。差别在于
 * **这条流的 `ready` 不携带集合** —— 就绪只说明「服务端开好了这条流」，客户端要的列表
 * 自己另读。那一条在这里有单独的判据，因为它是这条流与审批流最要紧的区别。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionListStreamTests: XCTestCase {

    private func read(_ text: String) throws -> SessionListReading {
        let frame = try XCTUnwrap(InboundFrame.decode(Data(text.utf8)), "这一帧该解得开：\(text.prefix(80))")
        return SessionListStreamReader.read(frame)
    }

    // MARK: - 开流帧

    /// 守的是「列表流用它自己那个工厂」：用 `approvals` 的工厂去开列表流，形状全对而网关
    /// 会把它当审批流，症状是列表永远不自己动。
    func testTheSessionListStreamOpensWithItsOwnOp() throws {
        let text = try SessionListStream().build("l1")
        XCTAssertEqual(text, #"{"payload":{"op":"session-list"},"streamId":"l1","type":"open"}"#)
    }

    func testTheLabelNamesThisStream() {
        XCTAssertEqual(SessionListStream().label, "session-list")
    }

    // MARK: - 判读：这条流只认两种 item

    func testReadyCarriesTheGenerationAndAbsenceStaysNil() throws {
        let withGeneration = try read(#"{"type":"item","streamId":"l1","payload":{"kind":"ready","generation":3}}"#)
        guard case .ready(let generation) = withGeneration.content else {
            return XCTFail("带代次的 ready 该判成 ready，实际：\(withGeneration.content)")
        }
        XCTAssertEqual(generation, 3)

        let withoutGeneration = try read(#"{"type":"item","streamId":"l1","payload":{"kind":"ready"}}"#)
        guard case .ready(let absent) = withoutGeneration.content else {
            return XCTFail("不带代次的 ready 同样是 ready，实际：\(withoutGeneration.content)")
        }
        XCTAssertNil(absent, "代次缺席表示源此刻没有活的代次 —— 不猜 0")
    }

    /// 载荷原样交出：四支 change 的解释归 `SessionListChange.decode`，这一层不解释。
    func testTheChangeCargoIsHandedOverVerbatim() throws {
        let reading = try read("""
        {"type":"item","streamId":"l1","payload":{"kind":"session-list","change":
          {"kind":"added","row":{"id":"s1","updatedAt":100,"running":false,"blank":false}}}}
        """)
        guard case .change(let payload) = reading.content else {
            return XCTFail("session-list 该判成 .change，实际：\(reading.content)")
        }
        XCTAssertEqual(payload["kind"]?.string, "session-list", "载荷原样，含 kind 自己")
        XCTAssertEqual(payload["change"]?["kind"]?.string, "added")
    }

    /// 别的流的货物落到这条流上 —— 一律丢弃。
    ///
    /// 网关按流分派（`stream.split.test.ts` 的 U4），客户端也要自己守住：网关的错版本、
    /// 或者有人把泵改回去，症状会是「列表里冒出一张审批卡的内容」。
    func testCargoesFromOtherStreamsAreIgnored() throws {
        for kind in ["waterfall", "cancel", "emit"] {
            let reading = try read("""
            {"type":"item","streamId":"l1","payload":{"kind":"\(kind)","eventId":"e1","event":"x","args":[]}}
            """)
            XCTAssertEqual(reading.content, .ignored, "\(kind) 不属于列表流")
            XCTAssertFalse(reading.establishes, "\(kind) 不建立这条流")
        }
    }

    func testRefusalKeepsCodeAndMessage() throws {
        let reading = try read(#"{"type":"error","streamId":"l1","payload":{"code":"source-unavailable","message":"not ready"}}"#)
        guard case .refused(let failure) = reading.content else {
            return XCTFail("error 帧该判成 refused，实际：\(reading.content)")
        }
        XCTAssertEqual(failure.code, GatewayErrorCode.sourceUnavailable.rawValue)
        XCTAssertEqual(failure.message, "not ready")
    }

    func testUnrecognizedShapesAreIgnoredRatherThanGuessed() throws {
        XCTAssertEqual(try read(#"{"type":"item","streamId":"l1","payload":{"nokind":true}}"#).content, .ignored)
        XCTAssertEqual(try read(#"{"type":"nonsense","streamId":"l1"}"#).content, .ignored)
    }

    // MARK: - 流层要读的两格

    /// 只有 `ready` 建立这条流。
    func testOnlyReadyEstablishesTheStream() throws {
        XCTAssertTrue(try read(#"{"type":"item","streamId":"l1","payload":{"kind":"ready"}}"#).establishes)
        XCTAssertFalse(try read(#"{"type":"item","streamId":"l1","payload":{"kind":"session-list","change":{"kind":"removed","id":"s1"}}}"#).establishes)
    }

    func testTheNextActionFollowsWhetherARetryCanHelp() throws {
        XCTAssertEqual(try read(#"{"type":"end","streamId":"l1"}"#).next, .reopen)
        XCTAssertEqual(
            try read(#"{"type":"error","streamId":"l1","payload":{"code":"source-unavailable","message":"x"}}"#).next,
            .retry, "源没就绪会变好 —— 值得再试")
        XCTAssertEqual(
            try read(#"{"type":"error","streamId":"l1","payload":{"code":"unknown-op","message":"x"}}"#).next,
            .stop, "这台网关不认 session-list —— 再开一万次也一样")
    }

    // MARK: - 收端的分派

    /// 每一条 `ready` 都叫一次代次听众，**不比较新旧**。
    ///
    /// 这条判据是「重连之后列表追平」的根：`SessionListState` 把每个代次都当成重读的界线，
    /// 而它依赖的正是「网关每次开流都发一条 ready」这个事实。
    func testGenerationListenersFirePerReadyIncludingSourceLoss() {
        let stream = SessionListStream()
        var seen: [Int?] = []
        stream.onGeneration { seen.append($0) }

        stream.handle(SessionListReading(content: .ready(generation: 5)))
        stream.handle(SessionListReading(content: .ready(generation: 5)))
        stream.handle(SessionListReading(content: .ready(generation: nil)))

        XCTAssertEqual(seen.count, 3, "同一个代次来两次也要叫两次")
        XCTAssertNil(stream.generation, "最后一条不带代次 —— 值归 nil")
    }

    /// 增量只到增量那个听众。
    func testChangeReachesItsOwnListener() {
        let stream = SessionListStream()
        var changes: [JSONValue] = []
        stream.onChange { changes.append($0) }

        let one: JSONValue = .object(["kind": .string("session-list"), "change": .object(["kind": .string("removed"), "id": .string("s1")])])
        stream.handle(SessionListReading(content: .change(one)))

        XCTAssertEqual(changes, [one])
    }

    /// 退订按身份摘一个；摘两次不炸。
    func testUnsubscribingRemovesOnlyThatListener() {
        let stream = SessionListStream()
        var first = 0
        var second = 0
        let offFirst = stream.onChange { _ in first += 1 }
        stream.onChange { _ in second += 1 }

        let change: JSONValue = .object(["kind": .string("session-list")])
        stream.handle(SessionListReading(content: .change(change)))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)

        offFirst()
        offFirst()
        stream.handle(SessionListReading(content: .change(change)))
        XCTAssertEqual(first, 1, "摘下之后不再收")
        XCTAssertEqual(second, 2, "另一个听众不受影响")
    }
}
