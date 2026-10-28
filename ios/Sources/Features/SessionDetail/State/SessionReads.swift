/**
 * 会话内容的两次读取：打开窗口（快照）与往回翻（分页）。
 *
 * 它们不在这层之外，是因为**只有会话详情需要窗口** —— 请求怎么拼、缺字段怎么说，
 * 与「镜像什么时候该要下一段」是同一件事的两头。协议形状仍在
 * `Core/Gateway/Wire/SessionMessages.swift`，这里只决定这一次问什么、拿回来的怎么落地。
 *
 * 两条都**不吞错**：`refused` 与传输失败由调用方分成两种说法，这层不做归类。
 */
import Foundation

/// 拉某会话的快照。
/// - Parameter since: 客户端**下一个期望的 seq** —— 由本地镜像记着，不是每次传 0。
@MainActor
func readSnapshot(
    _ client: RpcClient,
    sessionId: String,
    since: Int
) async throws -> SessionSnapshot {
    let response: SnapshotResponse = try await client.perform(
        SnapshotRequest(sessionId: sessionId, since: since)
    )
    // 缺载荷抛错，不填默认值；报的是缺了哪个字段（句子归 `FailureText`）。
    guard let asOfSeq = response.asOfSeq, let events = response.events else {
        throw RpcClientError.malformedResponse(detail: "asOfSeq / events")
    }
    return SessionSnapshot(
        asOfSeq: asOfSeq,
        // 缺省 `false`：不带这个字段的是旧服务端，它只会一次给完。
        hasMore: response.hasMore ?? false,
        events: events,
        // 基线：服务端「不知道」时整个缺省 —— 客户端退到目录默认，不猜。
        model: response.model
    )
}

/// 拉一段回溯窗口 —— 打开会话与往回翻都用它。
/// - Parameters:
/// - beforeSeq: 窗口上界（不含）。不传表示「从最新往回」（打开会话）；
///   往回翻时传上一次的 `pageStart`。

@MainActor
func readPage(
    _ client: RpcClient,
    sessionId: String,
    beforeSeq: Int? = nil,
) async throws -> SessionPage {
    let response: PageResponse = try await client.perform(
        PageRequest(sessionId: sessionId, beforeSeq: beforeSeq)
    )
    // 同上：缺载荷抛错。
    guard let pageStart = response.pageStart,
          let asOfSeq = response.asOfSeq,
          let hasOlder = response.hasOlder,
          let events = response.events else {
        throw RpcClientError.malformedResponse(
            detail: "pageStart / asOfSeq / hasOlder / events"
        )
    }
    return SessionPage(
        pageStart: pageStart,
        asOfSeq: asOfSeq,
        hasOlder: hasOlder,
        events: events
    )
}
