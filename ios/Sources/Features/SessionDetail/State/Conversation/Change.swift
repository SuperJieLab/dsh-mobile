/**
 * 一次写入的结果：**什么时候该发布**，以及**哪些槽位变了**。
 *
 * 两件事合成一个值，是因为驱动方总是同时需要它们：只知时机不知变化，就得回头全量重建；
 * 只知变化不知时机，就会每个 chunk 刷一次。
 *
 * `rebuilt` 是「说不清变了哪些」的显式表达 —— 位置索引被整份重建（前插、边界事件、
 * 带定稿的收笔）或整段窗口重来。这时 `touched` 不可信，驱动方**必须走全量**。
 * 把它当成「没有变化」会丢掉行；把它当成「只有 touched 变了」会丢掉位置变了的行。
 */
import Foundation

struct Change: Equatable {

    var publication: Publication
    /// 本次写入触及的槽位 key。`rebuilt` 为真时不可信。
    var touched: Set<String>
    /// 变化集说不清 —— 驱动方走全量。
    var rebuilt: Bool

    static let none = Change(publication: .none, touched: [], rebuilt: false)

    /// 说不清变化集的一次发布。
    static func full(_ publication: Publication) -> Change {
        Change(publication: publication, touched: [], rebuilt: true)
    }

    /// 并入一次写入：时机取最大，变化取并集，说不清的一律说不清。
    mutating func absorb(_ other: Change) {
        publication = Publication.maximum(publication, other.publication)
        touched.formUnion(other.touched)
        rebuilt = rebuilt || other.rebuilt
    }
}
