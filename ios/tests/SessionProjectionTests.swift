/**
 * 投影单元自己的判据 —— 以 `SessionProjection` 为被测对象，不经过编排层的转发面。
 *
 * 守的是「一批事件进来，屏幕上那一列变成什么」：顺序、去重、整段重建之后不接旧身份。
 * 帧的种类分派（打开帧 / 事件帧 / 草稿帧）另有 `SessionSyncTests` 从上层验，这里只喂批。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SessionProjectionTests: XCTestCase {

    /// 一条用户消息 —— 消息是最简单的可见节点，顺序一眼看得出。
    private func message(_ seq: Int, _ text: String) -> SessionEvent {
        SessionEvent(type: "user/message", seq: seq, time: Double(seq), data: .object([
            "id": .string("m-\(seq)"),
            "source": .object(["kind": .string("user")]),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]))
    }

    private func window(_ events: [SessionEvent]) -> SessionWindow {
        SessionWindow(
            records: events.map { SessionRecord(type: "user/message", event: $0) },
            cursor: events.last?.seq ?? 0,
            hasMore: false
        )
    }

    /// 一套最小的装配：输入单元管窗口，投影只管引擎与快照。
    private func make() -> (SessionInput, SessionProjection) {
        let input = SessionInput(sessionId: "s-1", control: nil)
        let projection = SessionProjection(sessionId: "s-1", input: input,
                                           statusBox: SessionStatus(),
                                           models: SessionModelMirror())
        return (input, projection)
    }

    private func texts(_ projection: SessionProjection) -> [String] {
        projection.snapshot.nodes.compactMap { node -> String? in
            if case .message(let message) = node.data { return message.text }
            return nil
        }
    }

    /// 一批事件进来：节点数与顺序都要对。
    func testABatchBecomesNodesInOrder() {
        let (input, projection) = make()
        for seq in 0..<3 {
            _ = input.append(message(seq, "第\(seq)条"))
        }

        projection.refresh()

        XCTAssertEqual(texts(projection), ["第0条", "第1条", "第2条"],
                      "顺序或条数不对 —— 喂食与物化之间漏了一步")
    }

    /// 重连时排回的那一批里，已经进过引擎的那些不再重导。
    ///
    /// 场景要「半新半旧」：整窗原样排回时两种实现都会走全量物化，看不出差别；只有当批里
    /// 既有旧的又有新的，去重那一步才决定「追加一条」还是「整段重建」。
    func testAReplayedBatchOnlyImportsTheNewRecords() {
        let (input, projection) = make()
        let events = (0..<4).map { message($0, "第\($0)条") }
        for event in events.prefix(3) { _ = input.append(event) }
        projection.refresh()
        XCTAssertEqual(texts(projection).count, 3, "先确认前三条真的上去了")

        let before = projection.buildViewNodeCount
        // 重连送回来的窗口从第 3 条起：排回的批 = 0…3，其中 0…2 已经在引擎里。
        _ = input.realign(with: window(events))
        projection.refresh()

        let growth = projection.buildViewNodeCount - before
        XCTAssertLessThanOrEqual(growth, 1,
                                 "重连把整窗重导了一遍（多导 \(growth) 格）—— 去重那一步失效了")
        XCTAssertEqual(texts(projection), ["第0条", "第1条", "第2条", "第3条"])
    }

    /// 整段重建之后不接旧身份。
    ///
    /// **前置是清窗口**：不清的话 `feedEngine` 在空引擎上会拿整份窗口（`input.records`）
    /// 重建一次，旧批会原样回来 —— 那正是重建这条路径要避免的事。
    func testARebuildStartsFromTheNewWindowOnly() {
        let (input, projection) = make()
        for seq in 0..<3 {
            _ = input.append(message(seq, "旧-\(seq)"))
        }
        projection.refresh()
        XCTAssertEqual(texts(projection).count, 3, "先确认旧窗口真的进去了")

        input.reset()
        projection.rebuild()
        projection.refresh()
        XCTAssertEqual(texts(projection), [], "重建之后引擎该是空的")

        for seq in 0..<2 {
            _ = input.append(message(seq, "新-\(seq)"))
        }
        projection.refresh()

        XCTAssertEqual(texts(projection), ["新-0", "新-1"], "旧窗口的内容被接回来了")
    }
}
