/**
 * 输入框那一行的状态：草稿、能不能发、面板该不该开、发出去之后草稿留不留。
 *
 * 这些都是判定，所以住在这里而不是视图里。视图只做三件事：把 `text` 绑到 `TextField`、
 * 读 `paletteQuery` 决定画不画面板、按发送时调 `submit`。
 *
 * **草稿只在「已受理」之后清空。** 命令名字打错（`unknown-command`）是本期唯一用户能自己
 * 改好的失败 —— 那条路上把输入框清掉，等于让人重打整行。
 *
 * **面板与分流读同一份归一化文本。** 各读一份原始草稿时，`" /permission"`（前导空格）会让
 * 面板判「不在敲命令」（不弹、不重拉）而发送判「是命令」：用户看不到任何候选，却执行了一条命令。
 *
 * 投递动作由外部注入（`submit(_:)` 的入参）—— 本类不认识网关，每条断言都不必起服务。
 */
import Foundation

@MainActor
@Observable
final class ComposerState {

    /// 草稿。`TextField` 双向绑定它。
    var text = ""

    /// 正在投递 —— 挡住连按（`canSubmit` 只判文本，不含它；按钮的置灰读 `canSubmit`）。
    private(set) var isSubmitting = false

    /// 投递一条：入参是已经分好流的那一行，返回值是**是否已受理**。
    typealias Deliver = @MainActor (SlashDispatch) async -> Bool

    /// 能发吗。与 `submit` 里的取值读同一份判定 ——「判空」与「取值」同源。
    var canSubmit: Bool {
        PromptDraft.normalized(text) != nil
    }

    /// 面板此刻该显示什么查询串；`nil` = 面板收起。
    ///
    /// 判之前**只去掉前导空白，保留尾随空白** —— 这是它和 `submit` 唯一的差别，而且是必要的：
    /// - 前导空白不该影响「在不在敲命令」（`" /per"` 归一化后是 `/per`，交给命令通道，
    ///   面板若判收起，用户就在看不到候选的情况下执行了一条命令）；
    /// - 尾随空白**是「已经进到参数里」的信号**（`"/permission "`），把它 trim 掉之后
    ///   面板会一直开着，挡住用户写参数。
    var paletteQuery: String? {
        let leadingStripped = text.drop(while: { $0.isWhitespace })
        guard case .querying(let query) = SlashTrigger.of(draft: String(leadingStripped)) else {
            return nil
        }
        return query
    }

    /// 选中一条候选之后草稿该是什么 —— 只回填，不执行（用户还要补参数、自己按发送）。
    func pick(name: String) {
        text = SlashTrigger.insert(name: name)
    }

    /// 提交一次。
    ///
    /// - Returns: 是否已受理。受理后清空草稿；没送到就原样留着。
    @discardableResult
    func submit(_ deliver: Deliver) async -> Bool {
        guard !isSubmitting, let normalized = PromptDraft.normalized(text) else { return false }
        isSubmitting = true
        defer { isSubmitting = false }

        let accepted = await deliver(SlashTrigger.dispatch(of: normalized))
        if accepted { text = "" }
        return accepted
    }
}
