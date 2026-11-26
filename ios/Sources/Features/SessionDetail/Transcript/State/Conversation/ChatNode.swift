/**
 * 渲染层唯一消费的节点形状 —— 一行画什么、用哪个身份、排在哪。
 *
 * 身份（`key`）与可见性（`visibility`）是两件事：内容被清空的节点不消失，只转 `hidden`。
 * 这正是「流式转定稿不闪」的另一半 —— 只换 id 而不管可见性，删除重建会回来。
 */
import Foundation

enum NodeVisibility: Equatable {
    case visible
    /// 存在但不上屏。它仍然占着身份，也仍然有数据（可能是空内容）。
    case hidden
}

struct ChatNode: Identifiable, Equatable {
    /// 身份。由引擎按 `(kind, id)` 生成，同一个槽位从生到死不变。
    /// `Identifiable` 认这一个 —— 业务标识可能跨 kind 撞号（消息 id 与轮次号同形），
    /// 拿它当列表身份会让 SwiftUI 把两行当成同一行。
    let key: String
    var id: String { key }
    let kind: String
    /// 业务标识（`turn:step`、`turn`、`commandId`、消息 id）。排错与判据读它，不当列表身份。
    let businessId: String
    /// 排序位置 —— 允许小数（未定稿帧落在两条持久事件之间）。
    let anchorSeq: EventOrder
    let visibility: NodeVisibility
    let data: ChatNodeData

    /// 这一行算不算「一条消息」—— 气泡与回复算，过程行与命令行不算。
    var isMessage: Bool {
        switch data {
        case .message, .assistant: return true
        case .process, .command: return false
        }
    }
}

enum ChatNodeData: Equatable {
    case assistant(AssistantNodeData)
    case message(MessageNodeData)
    case process(ProcessNodeData)
    case command(CommandRun)
}

/// 一次排序的结果。`nodes` 含 hidden —— 判据要看得到它们，渲染层只看 `visibleNodes`。
///
/// **可见节点与消息条数在构造时算一次。** 它们是视图每帧都要读的两格，做成计算属性
/// 就是「每帧全量过滤一遍 + 每帧全量遍历一遍」。算一次的开销与「取全量」同阶，摊在
/// 刷新里；读的那一侧变成取值。
struct ChatSnapshot: Equatable {
    let nodes: [ChatNode]

    /// 上屏的那一半。构造时定，读它不分配。
    ///
    /// 它是 `nodes` 的子集，按同一谓词有序。**hidden 的多少不影响增量合并的代价** ——
    /// 两张表各按 key 二分找位，只碰这一格；见 `ChatSnapshotBuilder.apply`。
    let visibleNodes: [ChatNode]

    /// 可见的消息与回复有多少条（命令行与过程行不算）。构造时定，读它不遍历。
    let messageCount: Int

    /// 全量路径：一次遍历同时产出可见集与条数。
    init(nodes: [ChatNode]) {
        self.nodes = nodes
        var kept: [ChatNode] = []
        kept.reserveCapacity(nodes.count)
        var count = 0
        for node in nodes {
            guard node.visibility == .visible else { continue }
            kept.append(node)
            if node.isMessage { count += 1 }
        }
        self.visibleNodes = kept.count == nodes.count ? nodes : kept
        self.messageCount = count
    }

    /// 增量路径：可见集与条数由调用方按「改了几格」算好，不回头扫全表。
    init(nodes: [ChatNode], visibleNodes: [ChatNode], messageCount: Int) {
        self.nodes = nodes
        self.visibleNodes = visibleNodes
        self.messageCount = messageCount
    }

    static let empty = ChatSnapshot(nodes: [])
}
