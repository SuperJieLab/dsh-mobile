/**
 * 审批卡上说给用户的两句话。
 *
 * 与 `ApprovalStore` 的分工：那边决定「什么时候说、说不说」（不能应答时说未转发、
 * 应答成功说已投递），这里只决定「怎么说」。改一句话不动判定。
 */
import Foundation

extension ApprovalStore {

    /// 不能应答时的说明。卡上显示它、应答的兜底也读它 —— 同一件事只写一处。
    static let notForwardedNote = "这条审批还没有经由网关转发到手机 —— "
        + "请在 Mac 上处理，或稍候重进会话。"

    /// 应答已投递。`allow` 决定说哪一个动作。
    static func deliveredNote(allow: Bool) -> String {
        allow ? "已投递：允许" : "已投递：拒绝"
    }
}
