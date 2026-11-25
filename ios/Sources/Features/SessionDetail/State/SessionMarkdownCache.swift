/**
 * 一个会话一份排版缓存 —— 寿命跟着会话，不跟着进程。
 *
 * 为什么不做全局静态：全局缓存的淘汰与任何会话无关，两个长会话交替看会互相挤占，
 * 而回翻要的恰恰是「刚才看过的那一屏还在」。全局静态还有个更静默的代价 —— 它永不释放。
 *
 * 为什么键是源文、桶是会话：「要不要重解析」由内容决定（同一段源文只解析一次，
 * 内容变了自然不命中）；「谁跟谁抢位置」由会话决定。两件事各归各的维度。
 */
import Foundation

final class SessionMarkdownCache {

    /// 解析次数。**为判据而留的读数**：它证明「回翻没再解析」，而这件事没有别的可观测面。
    private(set) var parseCount = 0

    private let limit: Int
    private var store: [String: MarkdownParseResult] = [:]
    /// 最近访问序（尾部最新）。命中也要把键移到尾部 —— 否则淘汰的是「最先写入的」，
    /// 而回翻看的是「刚才看过的」，两者正好相反。
    private var order: [String] = []
    private let lock = NSLock()

    /// - Parameter limit: 保留多少段源文。按「一屏槽位数 × 若干页」给，不按会话历史长度给。
    init(limit: Int = 240) {
        self.limit = limit
    }

    /// 没有会话可归属时用的那一份：**容量为零**，什么都存不下。
    ///
    /// 它给 `@Entry` 的默认值用 —— 那个默认值是逐次求值的，若写成 `SessionMarkdownCache()`
    /// 就会「每求值一次新建一份空缓存」，而症状只是慢。容量零的共享实例把这件事变成
    /// 可解释的退化：没注入就没有缓存，不假装有。真要有缓存，得由 `SessionDetailState` 播种
    /// （`testTheMarkdownCacheIsActuallyPlanted` 守着那一行）。
    static let unplanted = SessionMarkdownCache(limit: 0)

    func result(for source: String) -> MarkdownParseResult {
        lock.lock()
        if let hit = store[source] {
            touch(source)
            lock.unlock()
            return hit
        }
        lock.unlock()

        // 解析放锁外：它可能很久，不该挡住同一会话里别的视图取缓存。
        let parse = MarkdownParser.parse(source)

        lock.lock()
        // 双检：解析期间别的线程可能已经填上了同一段。
        if let hit = store[source] {
            touch(source)
            lock.unlock()
            return hit
        }
        store[source] = parse
        parseCount += 1
        order.append(source)
        if order.count > limit {
            store.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return parse
    }

    /// 把键移到最近访问的尾部。调用方必须持锁。
    private func touch(_ source: String) {
        if let index = order.lastIndex(of: source) {
            order.remove(at: index)
        }
        order.append(source)
    }
}
