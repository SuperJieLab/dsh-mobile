/**
 * 把节点排成屏幕上那一列。
 *
 * 排序键是 `anchorSeq`（可能是小数），第二键是 `key` —— 有了第二键，同一位置的两个节点
 * 每次重排都落在同一顺序上；没有它，测试与界面的顺序会随字典遍历顺序漂。
 *
 * 不做过滤：hidden 节点留在快照里，`visibleNodes` 只是它的子集。
 * 过滤放在定义之外会让「节点还在吗」变成「排序层说了算」，而那是定义的决定。
 */
import Foundation

struct ChatSnapshotBuilder {

    private(set) var snapshot: ChatSnapshot = .empty

    /// 走了几次全量构造。**只有判据读它** —— 「增量」与「全量」的产出完全一样，
    /// 差别只在代价上，而代价在这里是唯一可观测的。
    private(set) var fullRebuildCount = 0

    @discardableResult
    mutating func replace(_ nodes: [ChatNode]) -> ChatSnapshot {
        let ordered = nodes.sorted(by: Self.precedes)
        return rebuildAll(ordered)
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
    /// 代价是 O(改了几格)：`nodes` 与 `visibleNodes` 都是有序数组，两张表各按同一谓词
    /// 二分找位、就地替换，条数按「这一格算不算消息」加减。**hidden 的多少不影响这条路**
    /// —— 只要这一格没在可见与隐藏之间翻转，其余槽位就不必重算。
    /// 翻转、以及「同 key 却对不上位置」这类说不清的情形退全量，见 `rebuildRemaining`。
    @discardableResult
    mutating func apply(_ updated: [ChatNode]) -> ChatSnapshot {
        guard !updated.isEmpty else { return snapshot }

        var nodes = snapshot.nodes
        var visible = snapshot.visibleNodes
        var count = snapshot.messageCount

        for (index, node) in updated.enumerated() {
            let at = Self.insertionIndex(for: node, in: nodes)

            // 同一格：位置由 `(anchorSeq, key)` 定，位置对上就是它。
            if at < nodes.count, nodes[at].key == node.key {
                let old = nodes[at]
                guard old.visibility == node.visibility else {
                    return rebuildRemaining(nodes, remaining: updated[index...])
                }
                count += Self.delta(from: old, to: node)
                nodes[at] = node
                if node.visibility == .visible {
                    let visibleAt = Self.insertionIndex(for: node, in: visible)
                    guard visibleAt < visible.count, visible[visibleAt].key == node.key else {
                        return rebuildRemaining(nodes, remaining: updated[index...])
                    }
                    visible[visibleAt] = node
                }
                continue
            }

            // 锚点变了：先摘旧的，再按新位置插。
            if let stale = nodes.firstIndex(where: { $0.key == node.key }) {
                let old = nodes[stale]
                guard old.visibility == node.visibility else {
                    return rebuildRemaining(nodes, remaining: updated[index...])
                }
                count += Self.delta(from: old, to: node)
                nodes.remove(at: stale)
                if old.visibility == .visible {
                    let visibleAt = Self.insertionIndex(for: old, in: visible)
                    guard visibleAt < visible.count, visible[visibleAt].key == old.key else {
                        return rebuildRemaining(nodes, remaining: updated[index...])
                    }
                    visible.remove(at: visibleAt)
                }
                nodes.insert(node, at: Self.insertionIndex(for: node, in: nodes))
                if node.visibility == .visible {
                    visible.insert(node, at: Self.insertionIndex(for: node, in: visible))
                }
                continue
            }

            // 新槽位。
            nodes.insert(node, at: at)
            if node.visibility == .visible {
                visible.insert(node, at: Self.insertionIndex(for: node, in: visible))
                if node.isMessage { count += 1 }
            }
        }

        snapshot = ChatSnapshot(nodes: nodes, visibleNodes: visible, messageCount: count)
        return snapshot
    }

    /// 这一格「算不算一条消息」变了多少 —— 只算上屏的那一半。
    private static func delta(from old: ChatNode, to new: ChatNode) -> Int {
        Self.weight(of: new) - Self.weight(of: old)
    }

    private static func weight(of node: ChatNode) -> Int {
        node.visibility == .visible && node.isMessage ? 1 : 0
    }

    /// 说不清的那几支：把这一格连同剩下的改动一并并进去，整份重建。
    ///
    /// 「说不清」只有一种成因 —— 这一格在可见与隐藏之间翻转。那时它进出的同时，
    /// 其余槽位的相对位置并不变，但「变了哪些格」已经不是一句话能说清的了；
    /// 与其猜，不如退全量。翻转本身罕见（只在内容被清空的格子上发生）。
    private mutating func rebuildRemaining(
        _ nodes: [ChatNode],
        remaining: ArraySlice<ChatNode>
    ) -> ChatSnapshot {
        var merged = nodes
        Self.merge(Array(remaining), into: &merged)
        return rebuildAll(merged)
    }

    private mutating func rebuildAll(_ nodes: [ChatNode]) -> ChatSnapshot {
        fullRebuildCount += 1
        snapshot = ChatSnapshot(nodes: nodes)
        return snapshot
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
