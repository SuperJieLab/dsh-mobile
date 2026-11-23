/**
 * 往回翻一页。
 *
 * 住这一层是因为只有会话详情需要窗口；协议形状仍在 `Core/Gateway/Wire`，这里只决定这一次
 * 问什么。**不吞错**：`refused` 与传输失败由调用方分成两种说法。
 *
 * 打开那一屏不在这里 —— 它由订阅流的打开帧送来。从前这条路上还有一次 HTTP 快照，
 * 那条路随 HTTP 快照端点一起退场了：两个来源（流与 HTTP）各算一份水位，
 * 迟早有一个说「我读到 12」而另一个说「我读到 13」。
 */
import Foundation

/// 拉一段回溯窗口。
///
/// - Parameters:
///   - throughSeq: 日志切点（**含端**）。打开那一刻的 `cursor`，翻页期间原样带回 ——
///     它钉住「日志长到哪为止」，于是翻页途中新来的事件不会把这一页挤走。
///   - beforeSeq: 这一页往前到哪（**排他**）。每次取本地窗口起点递减。
@MainActor
func readPage(
    _ client: RpcClient,
    sessionId: String,
    throughSeq: Int,
    beforeSeq: Int
) async throws -> SessionWindow {
    let response: PageResponse = try await client.perform(
        PageRequest(sessionId: sessionId, throughSeq: throughSeq, beforeSeq: beforeSeq)
    )
    // 缺载荷抛错，不填默认值；报的是缺了哪个字段（句子归 `FailureText`）。
    guard let records = response.records, let cursor = response.cursor, let hasMore = response.hasMore else {
        throw RpcClientError.malformedResponse(detail: "records / cursor / hasMore")
    }
    // 坏记录单条跳过 —— 与打开帧同一条规则（那一格解不出的是一条事件，不是整页）。
    return SessionWindow(records: records.compactMap(\.value), cursor: cursor, hasMore: hasMore)
}
