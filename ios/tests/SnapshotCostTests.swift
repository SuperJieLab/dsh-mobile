/**
 * 快照的读口成本 —— 可见节点与消息条数在构造时算一次，读它们只是取值。
 *
 * 为什么单独一个文件：这两条判据守的不是行为，是「读不再计算」。它们绿了不代表界面对，
 * 但红了就说明每帧又在全量过滤一遍——那是长会话翻到顶时最贵的一处。
 */
import XCTest

@testable import DshMobile

final class SnapshotCostTests: XCTestCase {

    private func node(
        _ key: String,
        _ data: ChatNodeData,
        anchor: Double,
        visible: Bool = true
    ) -> ChatNode {
        ChatNode(
            key: key,
            kind: "k",
            businessId: key,
            anchorSeq: anchor,
            visibility: visible ? .visible : .hidden,
            data: data
        )
    }

    private func message(_ text: String, _ time: Double) -> ChatNodeData {
        .message(MessageNodeData(text: text, time: time))
    }

    private func assistant(_ text: String, _ time: Double) -> ChatNodeData {
        .assistant(AssistantNodeData(status: .settled, turn: 1, step: 1,
                                     text: text, blocks: [], time: time))
    }

    private func command(_ name: String) -> ChatNodeData {
        .command(CommandRun(commandId: "c-\(name)", name: name, args: nil, outcome: nil))
    }

    // MARK: - 可见节点是存储值

    func testVisibleNodesHoldsExactlyTheVisibleHalf() {
        let snapshot = ChatSnapshot(nodes: [
            node("m1", message("hi", 1), anchor: 1),
            node("a1", assistant("yo", 2), anchor: 2),
            node("c1", command("ls"), anchor: 3),
            node("m2", message("gone", 4), anchor: 4, visible: false),
        ])

        XCTAssertEqual(snapshot.visibleNodes.map(\.key), ["m1", "a1", "c1"],
                       "hidden 的节点不上屏，但它仍留在 nodes 里")
    }

    // MARK: - 消息条数是存储值

    func testMessageCountCountsOnlyVisibleMessagesAndReplies() {
        let snapshot = ChatSnapshot(nodes: [
            node("m1", message("hi", 1), anchor: 1),
            node("a1", assistant("yo", 2), anchor: 2),
            node("c1", command("ls"), anchor: 3),
            node("m2", message("gone", 4), anchor: 4, visible: false),
            node("a2", assistant("hidden", 5), anchor: 5, visible: false),
        ])

        XCTAssertEqual(snapshot.messageCount, 2,
                       "只数可见的消息与回复：命令行不算，hidden 的不算")
    }

    func testEmptySnapshotHasNoVisibleNodesAndNoMessages() {
        XCTAssertEqual(ChatSnapshot.empty.visibleNodes.count, 0)
        XCTAssertEqual(ChatSnapshot.empty.messageCount, 0)
    }

    // MARK: - 合并只碰给定的那些槽位

    func testApplyReplacesByKeyAndKeepsTheOrder() {
        var builder = ChatSnapshotBuilder()
        builder.replace([
            node("a", message("1", 1), anchor: 1),
            node("b", message("2", 2), anchor: 2),
            node("c", message("3", 3), anchor: 3),
        ])

        let snapshot = builder.apply([
            node("b", message("changed", 2), anchor: 2),
            node("d", message("4", 4), anchor: 4),
        ])

        XCTAssertEqual(snapshot.nodes.map(\.key), ["a", "b", "c", "d"],
                       "既有的位置不动，新的按位置插到它该在的地方")
        XCTAssertEqual(snapshot.nodes[1].data, message("changed", 2), "同一个 key 被换掉而不是复制一份")
    }

    func testApplyWithNothingChangedKeepsTheSnapshotAsItWas() {
        var builder = ChatSnapshotBuilder()
        let before = builder.replace([node("a", message("1", 1), anchor: 1)])

        XCTAssertEqual(builder.apply([]), before)
    }

    // MARK: - 重导只发生在命中的槽位上

    private func userMessage(_ seq: Int) -> AssemblyEvent {
        let json = #"{"id":"u\#(seq)","source":{"kind":"user"},"content":[{"type":"text","text":"m"}]}"#
        let data = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return AssemblyEvent(order: Double(seq), seq: seq, type: "user/message",
                             time: Double(seq), data: data)
    }

    private func engine() -> ConversationAssembler {
        ConversationAssembler(definitions: [
            AnyNodeDefinition(AssistantStepDefinition()),
            AnyNodeDefinition(MessageDefinition()),
            AnyNodeDefinition(ProcessDefinition()),
            AnyNodeDefinition(CommandDefinition()),
        ])
    }

    func testMaterializingTheTouchedSlotsCostsTheSameAtAnyHistoryLength() {
        func rebuildCount(_ historyLength: Int) -> Int {
            var assembler = engine()
            assembler.rebuild((0..<historyLength).map(userMessage))
            let change = assembler.append(userMessage(historyLength))
            let before = assembler.buildViewNodeCount
            _ = assembler.nodes(forKeys: change.touched)
            return assembler.buildViewNodeCount - before
        }

        let short = rebuildCount(500)
        let long = rebuildCount(3000)
        XCTAssertEqual(short, 1, "一条消息只该重导它自己那一格")
        XCTAssertEqual(long, short, "重导次数与历史长度无关")
    }

    func testFullMaterializationIsWhatGrowsWithHistory() {
        var assembler = engine()
        assembler.rebuild((0..<3000).map(userMessage))

        let before = assembler.buildViewNodeCount
        _ = assembler.nodes()
        XCTAssertEqual(assembler.buildViewNodeCount - before, 3000,
                       "全量重导的代价就是「每个槽位都算一遍」—— 这正是本期要绕开的那条路")
    }

    func testMergingAFramesWorthOfAppendsMaterializesOnlyOnce() {
        var assembler = engine()
        assembler.rebuild([userMessage(0)])

        var change = AssemblyChange.none
        for seq in 1...10 {
            change.absorb(assembler.append(userMessage(seq)))
        }

        XCTAssertFalse(change.rebuilt, "十条非边界追加都说得清自己变了哪些")
        XCTAssertEqual(change.touched.count, 10, "并集不能丢")

        let before = assembler.buildViewNodeCount
        _ = assembler.nodes(forKeys: change.touched)
        XCTAssertEqual(assembler.buildViewNodeCount - before, 10,
                       "一帧里十条也只重导十格，不是「每条各刷一次」")
    }

}
