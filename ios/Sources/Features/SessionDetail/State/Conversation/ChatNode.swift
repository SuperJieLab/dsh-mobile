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
}

enum ChatNodeData: Equatable {
    case assistant(AssistantNodeData)
    case message(MessageNodeData)
    case process(ProcessNodeData)
    case command(CommandRun)
}

/// 一次排序的结果。`nodes` 含 hidden —— 判据要看得到它们，渲染层只看 `visible`。
struct ChatSnapshot: Equatable {
    let nodes: [ChatNode]

    var visible: [ChatNode] {
        nodes.filter { $0.visibility == .visible }
    }

    static let empty = ChatSnapshot(nodes: [])
}
