/**
 * 问题卡的文案 —— 用户可见的句子只住这里。
 *
 * 与 `ApprovalText` 同一个理由：State 层不许有面向用户的字符串，它只说「发生了什么」，
 * 说给用户听的那句在这里。
 */
enum QuestionText {
    /// 应答已投递（结局由上游结算，客户端不推演）。
    static let deliveredNote = "已投递"
}
