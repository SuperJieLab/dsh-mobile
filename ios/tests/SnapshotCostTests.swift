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
        XCTAssertEqual(snapshot.visible.map(\.key), snapshot.visibleNodes.map(\.key),
                       "旧读口与新读口必须给出同一批节点")
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
}
