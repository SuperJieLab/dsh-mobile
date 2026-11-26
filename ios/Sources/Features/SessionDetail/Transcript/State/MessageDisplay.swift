/**
 * 屏幕上显示的一条消息气泡 —— 显示形状，不是线上形状。
 *
 * 消费者是 `SessionDetailView`：消息条数由组装好的节点数出来，不遍历事件另算一份。
 * 「哪些事件算一条消息」不在这里，在 `Definitions/` 里（每种节点一份定义）。
 */
import Foundation

struct DisplayMessage: Hashable {
    enum Role: Hashable {
        case user
        case assistant
    }

    let seq: Int
    let role: Role
    let text: String
    let time: Double
    /// 这一条还在生成中（源文逐帧增长）。
    ///
    /// 唯一的消费者是「构造时要不要取排版缓存」这个判断：还在跑的那条不取 —— 它每帧换一份
    /// 源文，写进缓存的是再也不会被读的中间态，而条目数按帧计，一段长回答足以把会话缓存
    /// 换一遍，回来的全是这些中间态。定稿之后才取，那时源文不再变。
    let isRunning: Bool
}
