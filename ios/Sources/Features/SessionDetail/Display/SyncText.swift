/**
 * 会话详情屏的**说法** —— 状态行那一句、底部告知那一句、重置理由的三种说法。
 *
 * 与 `State/SessionSync.swift` 分家的理由：句子随产品决定变，而「同步到哪一步、失败在哪一步」
 * 随协议与协议交互变。编排只产出 `Status.failed(step:cause:)`，说话归这里。
 *
 * 三种来源的句子都在这一个文件里，是因为它们同属一个变化原因（本屏的措辞），
 * 且互相引用（告知的两句都要重置理由的三种说法）。
 *
 * 消费者：`SessionDetailView`（状态行与底栏告知）。判定层不引用这里 ——
 * `LayeringTests.testSyncOrchestrationHasNoUserFacingStrings` 守着方向。
 *
 * ⚠️ **有几组「步 + 原因」目前到不了**：`sending` / `selecting` / `streaming` 上的
 * `transport` 与 `refusal`，以及 `opening` / `paging` / `syncing` 上的 `thrown` ——
 * 那几条路径捕获到的错误一律包成 `.thrown`，协议拒绝走 `.refusal`，镜像只说「没成」走
 * `.transport`。它们仍要写全（switch 得穷尽），但**不构成用户可见的说法**；
 * 将来哪条路径改了，这几支就是现成的。
 */
import Foundation

extension SessionSync.Status {

    /// 状态行的一句话。
    var line: String {
        switch self {
        case .idle:
            return "尚未同步"
        case .syncing:
            return "正在同步…"
        case .done(let added, let recovered):
            let prefix = recovered ? "已重新同步" : "已是最新"
            return added == 0 ? prefix : "\(prefix)，新增 \(added) 条"
        case .failed(let step, let cause):
            return cause.line(step: step)
        }
    }
}

extension SessionSync.Step {

    /// 这一步在**通用句式**里怎么称呼（只用于拒绝与兜底两支；其余各处逐条写死，
    /// 因为那几句的措辞不是「动作 + 失败」能拼出来的）。
    fileprivate var name: String {
        switch self {
        case .opening: return "打开"
        case .paging: return "读取"
        case .syncing: return "同步"
        case .sending: return "发送"
        case .selecting: return "换模型"
        case .streaming: return "订阅"
        }
    }
}

extension SessionSync.Cause {

    /// 一句失败 —— 「哪一步 + 哪一类原因」拼成一句。
    ///
    /// 同一类原因在不同步骤上说的话不一样，所以这里是一个二维表而不是一句通用文案：
    /// 打开时说「这一屏还是空的」，往回翻时说「未能加载更早的消息」。
    func line(step: SessionSync.Step) -> String {
        switch self {
        case .transport:
            switch step {
            case .opening: return "没连上网关 —— 这一屏还是空的。"
            case .paging: return "没连上网关 —— 未能加载更早的消息。"
            case .syncing: return "没连上网关 —— 手机上看到的仍是上一次同步的内容。"
            case .sending, .selecting, .streaming: return "没连上网关。"
            }

        case .refusal(let code):
            switch step {
            case .opening, .paging: return "服务端拒绝了这次读取：\(code)"
            case .syncing: return "服务端拒绝了这次同步：\(code)"
            case .sending, .selecting, .streaming:
                return "服务端拒绝了这次\(step.name)：\(code)"
            }

        case .resetLoop(let reason):
            return "服务端连续要求重新同步（\(reason.words)）—— 已停止重试。"

        case .thrown(let error):
            let detail = error.localizedDescription
            switch step {
            case .sending: return "指令没能送达：\(detail)"
            case .selecting: return "模型没换成：\(detail)"
            case .streaming: return "订阅流被拒绝：\(detail)"
            case .opening, .paging, .syncing: return "\(step.name)失败：\(detail)"
            }
        }
    }
}

extension ResetReason {

    /// 重置理由的人话说法。两处要用它（状态行的一句话、固定面上告知的一句话），
    /// 所以只在此处定义一次。
    var words: String {
        switch self {
        case .gap: return "中间有事件没拿到"
        case .waterMarkWentBack: return "服务端给的位置比本地还靠前"
        case .cursorVoid: return "本地记的位置在 Mac 上不存在了"
        }
    }
}

extension ResyncNotice {

    /// 固定面上的一句话 —— 三件事齐全：**发生了什么 / 丢了什么 / 怎么恢复**。
    ///
    /// 只说「有更新没接上」不够：用户离开屏幕时不知道自己失去了什么。原因里不含「丢了什么」，
    /// 就等于没说明白。
    var line: String {
        switch kind {
        case .unresolved:
            return "有更新没能接上（\(reason.words)）"
                + "—— 屏幕上仍是已读到的内容，下拉可重新同步。"
        case .reset:
            return "内容已清空重来（\(reason.words)）—— 已翻出来的更早历史随之丢失，下拉可重新载入。"
        }
    }
}
