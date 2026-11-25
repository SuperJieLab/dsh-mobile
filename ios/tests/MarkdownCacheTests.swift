/**
 * 会话级排版缓存的判据 —— 它守的是「回翻不再解析」，不是「解析得快」。
 *
 * 三条各挡一种错法：① 同会话回翻仍重解析（缓存没命中）；② 两个会话互相挤占
 * （仍是全局 FIFO）；③ 缓存活得比会话长（全局静态，永不释放）。
 */
import XCTest

@testable import DshMobile

final class MarkdownCacheTests: XCTestCase {

    /// 同一批源文再取一次，不该重新解析。
    func testTheSameConversationHitsWhenPagingBack() {
        let cache = SessionMarkdownCache(limit: 240)
        let page = (0..<100).map { "# 第 \($0) 条\n\n正文" }

        for source in page { _ = cache.result(for: source) }
        let afterFirst = cache.parseCount
        for source in page { _ = cache.result(for: source) }

        XCTAssertGreaterThan(afterFirst, 0, "一条都没解析 —— 判据本身没跑起来")
        XCTAssertEqual(cache.parseCount, afterFirst, "回翻同一批源文仍在解析")
    }

    /// 两个会话各占一份缓存，互不挤占。
    func testTwoConversationsDoNotEvictEachOther() {
        let mine = SessionMarkdownCache(limit: 8)
        let other = SessionMarkdownCache(limit: 8)
        for index in 0..<8 {
            _ = mine.result(for: "mine-\(index)")
            _ = other.result(for: "other-\(index)")
        }
        let before = mine.parseCount

        for index in 0..<8 { _ = mine.result(for: "mine-\(index)") }

        XCTAssertEqual(mine.parseCount, before, "另一个会话的条目把这一桶挤掉了 —— 缓存还是全局的")
    }

    /// 缓存必须随持有者释放。
    func testTheCacheDiesWithItsOwner() {
        weak var weakCache: SessionMarkdownCache?
        autoreleasepool {
            let cache = SessionMarkdownCache(limit: 4)
            weakCache = cache
            _ = cache.result(for: "x")
        }
        XCTAssertNil(weakCache, "缓存活过了持有者 —— 它还是全局静态的")
    }

    /// 超出容量时淘汰最旧的，但**命中的那条要活下来**（回翻看的是最近访问过的）。
    func testHittingAnEntryKeepsItAlive() {
        let cache = SessionMarkdownCache(limit: 3)
        _ = cache.result(for: "a")
        _ = cache.result(for: "b")
        _ = cache.result(for: "c")
        _ = cache.result(for: "a")            // 命中，a 变成最近访问
        _ = cache.result(for: "d")            // 挤掉最旧的（b）

        let before = cache.parseCount
        _ = cache.result(for: "a")
        XCTAssertEqual(cache.parseCount, before, "刚看过的那条被挤掉了 —— 淘汰顺序按写入而不是按访问")
    }
}
