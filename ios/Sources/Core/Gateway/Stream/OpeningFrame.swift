/**
 * opening 帧的 typed 形状（R4 决定 1）：帧原文**就地解码一次**，
 * 不再经 `JSONValue → Data → typed` 往返（对账判据 G1：与旧往返路径产出逐字一致）。
 *
 * 字段语义（与既有 JSONValue 判读逐字对齐）：
 * - `events` 走 `FailableDecodable`——坏事件单条跳过，其余照常显示；
 * - `model` / `occupancy` 用「Optional 包 FailableDecodable」区分
 *   「字段不在 = 服务端读不出，不猜」与「字段在 = 落地或丢弃」两件事；
 * - `assistantStream` 保持 `JSONValue` 原样——`parseBaseline` 只认声明字段，量小。
 */
import Foundation

struct OpeningFrame {
    let sessionId: String
    let pageStart: Int
    let cursor: Int
    let hasOlder: Bool
    let events: [SessionEvent]
    let assistantStream: JSONValue?
    let model: ModelSelection?
    let occupancy: UsageSnapshot?

    /// 首屏这一段，按状态机的输入形状给出。
    ///
    /// 这次改名（`cursor` → `asOfSeq`）在这里做，而不是让编排替它翻译：`cursor` 是订阅流的
    /// 说法（「已读到的位置」），`asOfSeq` 是 `page` 的说法（「窗口末尾，不含」）—— 它们是同一个
    /// 量的两个名字，改名应该由持有字段的那一侧负责（R19 决定 A2）。
    var page: SessionPage {
        SessionPage(pageStart: pageStart, asOfSeq: cursor, hasOlder: hasOlder, events: events)
    }

    /// 从 item 帧原文解码。形状不是 opening（缺 sessionId / cursor / events）返回 nil——
    /// 路由判据与既有 JSONValue 检查一致，误判不允许发生。
    static func decode(_ data: Data) -> OpeningFrame? {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let sessionId: String?
                let pageStart: Int?
                let cursor: Int?
                let hasOlder: Bool?
                let events: [FailableDecodable<SessionEvent>]?
                let assistantStream: JSONValue?
                let model: FailableDecodable<ModelSelection>?
                let occupancy: FailableDecodable<UsageSnapshot>?
            }
            let payload: Payload?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = envelope.payload,
              let sessionId = payload.sessionId,
              let cursor = payload.cursor,
              let failableEvents = payload.events else { return nil }
        return OpeningFrame(
            sessionId: sessionId,
            pageStart: payload.pageStart ?? 0,
            cursor: cursor,
            hasOlder: payload.hasOlder ?? false,
            events: failableEvents.compactMap(\.value),
            assistantStream: payload.assistantStream,
            model: payload.model?.value,
            occupancy: payload.occupancy?.value
        )
    }
}
