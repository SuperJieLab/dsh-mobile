/**
 * 权限那一格的说法 —— 四个档位的名字、`custom` 的写法、两段确认文案、失败那一句。
 *
 * 变化原因与 `State/PermissionState.swift` 不同：句子随产品决定变，三面的映射随协议变。
 * 判定不引用这里的句子 —— 编排文件里出现用户可见的中文字面量时分层判据会红。
 *
 * 内置档位的中文照上游客户端的词（`仅可查看` / `工作区内修改` / `完全权限` / `自动审查`），
 * 确认文案也照它的当前会话那一套 —— 两端对同一件事说同一句话，用户不必在两处重新理解。
 */
import Foundation

extension PermissionLabel {

    /// 格子上与菜单里的那个名字。宿主给的自定义名原样显示。
    var text: String {
        switch self {
        case .readOnly: return "仅可查看"
        case .workspaceWrite: return "工作区内修改"
        case .fullAccess: return "完全权限"
        case .autoReview: return "自动审查"
        case .custom: return "自定义"
        case .host(let name): return name
        }
    }
}

extension PermissionState {

    /// 还没拿到当前档时那一格写什么。与占用格同款：留位，不消失。
    static let unknownLabel = "--"

    /// 切档失败时功能条上方那一行。**服务端原文优先**：协议码不认识时原样给 message。
    var failureLine: String? {
        guard let failure else { return nil }
        switch failure {
        case .refused(let refused):
            return "没能切换权限：\(refused.readableDescription)"
        case .offline:
            return "没能切换权限 —— 没连上网关。"
        }
    }
}

extension PermissionState.Choice {

    /// 确认框的三段文字。**只有需要确认的档位有**（其余档位直接切，不弹）。
    ///
    /// 文案照上游当前会话那一套；「自动审查」多一句「实验」，因为它会额外消耗 token
    /// 且可能误放行 —— 那一句是用户做决定时要的信息，不能省。
    var confirmation: (title: String, message: String, confirm: String)? {
        switch value {
        case "danger-full-access":
            return (
                title: "确认启用完全权限？",
                message: "启用完全权限后，智能体将减少确认步骤，并且可以直接执行更多操作，"
                    + "包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。",
                confirm: "启用完全权限"
            )
        case "auto":
            return (
                title: "确认启用自动审查（实验）？",
                message: "自动审查不使用沙箱。每次工具调用前由与当前智能体相同的模型判断是否放行，"
                    + "它拒绝的调用由你批准或拒绝。此功能仍属实验性，可能误放行或误拒绝，"
                    + "并会消耗额外 token。",
                confirm: "启用自动审查"
            )
        default:
            return nil
        }
    }

    /// 确认框上的那一句「我已了解风险」。
    static let acknowledge = "我已了解风险，并愿意继续"
    /// 确认框的取消按钮。
    static let cancel = "取消"
}
