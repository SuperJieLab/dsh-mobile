/**
 * 把节点排成屏幕上那一列。
 *
 * 排序键是 `anchorSeq`（可能是小数），第二键是 `key` —— 有了第二键，同一位置的两个节点
 * 每次重排都落在同一顺序上；没有它，测试与界面的顺序会随字典遍历顺序漂。
 *
 * 只做排序，不做过滤：hidden 节点留在快照里，渲染层自己取 `visible`。
 * 过滤放在这里会让「节点还在吗」变成「排序层说了算」，而那是定义的决定。
 */
import Foundation

struct ChatSnapshotBuilder {

    private(set) var snapshot: ChatSnapshot = .empty

    @discardableResult
    mutating func replace(_ nodes: [ChatNode]) -> ChatSnapshot {
        let ordered = nodes.sorted(by: Self.precedes)
        snapshot = ChatSnapshot(nodes: ordered)
        return snapshot
    }

    /// 先按位置、再按身份。第二键不是装饰：同一位置上会有两个节点（过程与答案），
    /// 没有它，顺序随字典遍历漂，界面与判据都会跟着抖。
    private static func precedes(_ left: ChatNode, _ right: ChatNode) -> Bool {
        if left.anchorSeq != right.anchorSeq { return left.anchorSeq < right.anchorSeq }
        return left.key < right.key
    }
}
