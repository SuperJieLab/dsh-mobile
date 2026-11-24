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

    /// 按 key 并入：给定节点替换同 key 的旧条目，没有的按位置插入。
    ///
    /// **只用在不会改变整体顺序的路径上**（追加一条实时事件、就地更新某一格）。
    /// 位置索引被整份重建之后（前插、边界事件、带定稿的收笔）必须走 `replace`：
    /// 那时任意槽位的锚点都可能变，按 key 并会把顺序搞错。
    ///
    /// 代价是 O(改了几格)：常见情形（没有 hidden 节点）下可见集就是 `nodes` 本身，
    /// 条数按「这一格算不算消息」加减，不回头扫全表。有 hidden 节点时索引不再一一
    /// 对应，退回一次全量构造 —— 那种情形只在「内容被清空的格子」出现。
    @discardableResult
    mutating func apply(_ updated: [ChatNode]) -> ChatSnapshot {
        guard !updated.isEmpty else { return snapshot }
        let allVisible = snapshot.nodes.count == snapshot.visibleNodes.count
        guard allVisible, updated.allSatisfy({ $0.visibility == .visible }) else {
            var merged = snapshot.nodes
            Self.merge(updated, into: &merged)
            snapshot = ChatSnapshot(nodes: merged)
            return snapshot
        }

        var nodes = snapshot.nodes
        var count = snapshot.messageCount
        for node in updated {
            var at = Self.insertionIndex(for: node, in: nodes)
            if at < nodes.count, nodes[at].key == node.key {
                count += Self.delta(from: nodes[at], to: node)
                nodes[at] = node
                continue
            }
            if let stale = nodes.firstIndex(where: { $0.key == node.key }) {
                count += Self.delta(from: nodes[stale], to: node)
                nodes.remove(at: stale)
                at = Self.insertionIndex(for: node, in: nodes)
            } else if node.isMessage {
                count += 1
            }
            nodes.insert(node, at: at)
        }
        snapshot = ChatSnapshot(nodes: nodes, visibleNodes: nodes, messageCount: count)
        return snapshot
    }

    /// 这一格「算不算一条消息」变了多少。
    private static func delta(from old: ChatNode, to new: ChatNode) -> Int {
        (new.isMessage ? 1 : 0) - (old.isMessage ? 1 : 0)
    }

    /// 全量兜底用的合并：换同 key、按位置插。
    private static func merge(_ updated: [ChatNode], into nodes: inout [ChatNode]) {
        for node in updated {
            var at = insertionIndex(for: node, in: nodes)
            if at < nodes.count, nodes[at].key == node.key {
                nodes[at] = node
                continue
            }
            if let stale = nodes.firstIndex(where: { $0.key == node.key }) {
                nodes.remove(at: stale)
                at = insertionIndex(for: node, in: nodes)
            }
            nodes.insert(node, at: at)
        }
    }

    /// `node` 在已排序数组里该在的下标。同一 `(anchorSeq, key)` 的旧条目正好落在这里。
    private static func insertionIndex(for node: ChatNode, in nodes: [ChatNode]) -> Int {
        var low = 0
        var high = nodes.count
        while low < high {
            let mid = (low + high) / 2
            if precedes(nodes[mid], node) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
