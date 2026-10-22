/**
 * 审批卡上说给用户的两句话。
 *
 * 与 `ApprovalStore` 的分工：那边决定「什么时候说、说不说」（应答成功说已投递、
 * 这条已经不在了说原因），这里只决定「怎么说」。改一句话不动判定。
 */
import Foundation

extension ApprovalStore {

    /// 应答已投递。`allow` 决定说哪一个动作。
    static func deliveredNote(allow: Bool) -> String {
        allow ? "已投递：允许" : "已投递：拒绝"
    }

    /// 已经发出、回包还没到。
    static let sendingNote = "正在发送…"

    /// 已发出但结果未知。
    static let unknownNote = "已发出，结果未知 —— 等待 Mac 端回执，或重新打开本会话。"
}
