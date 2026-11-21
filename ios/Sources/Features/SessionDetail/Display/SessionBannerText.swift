/**
 * 详情页横幅的文案 —— 用户可见的句子只住这里。
 *
 * 与 `ApprovalText` / `QuestionText` 同一条纪律：State 层只说「发生了什么」，
 * 说给用户听的那句在 Display 层。
 */
enum SessionBannerText {
    /// 账号过期：只提示，不清凭证 —— 清票是身份域的判断，在这里顺手删会让
    /// 「重连一次就好」变成「重新配对」。
    static let loginExpired = "登录已失效 —— 这台 Mac 上的账号过期了。重新登录之后这一屏会恢复。"
}
