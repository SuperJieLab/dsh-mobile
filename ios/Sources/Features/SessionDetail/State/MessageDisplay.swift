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
}
