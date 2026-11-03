/**
 * 会话内「当前显示哪个模型」的唯一持有者。
 *
 * 三个方向都在写它：opening 基线、`model/selection` 与 `request/header` 事件、本机一次
 * `model-select` 的回包。前两个住在读侧编排里，第三个住在写侧 —— 所以镜像不能跟着任何
 * 一边走，否则另一边就会自己算一份，两处一旦不同步，功能条显示的是 A、实际下一轮用的是 B。
 *
 * 判定（水位、代号对号）仍在值类型 `ModelSelectionState` 里，这里只管「把它拿出来当状态」。
 */
import Foundation

@MainActor
@Observable
final class SessionModelMirror {

    /// 当前显示的选择。`nil` = 还不知道 —— 界面退到目录默认，不猜。
    private(set) var displayed: ModelSelection?

    private var state = ModelSelectionState()

    /// 吸收 opening 基线：服务端从全会话投影算出的「下一轮用什么」，无条件落地。
    func absorb(baseline: ModelSelection?) {
        state.absorb(baseline: baseline)
        displayed = state.displayed
    }

    /// 吸收一条流事件；水位与形状判定在值类型里。
    func absorb(event: SessionEvent) {
        state.absorb(event: event)
        displayed = state.displayed
    }

    /// 发起一次选择：取回代号，回包时凭它对号。
    func beginSelect() -> Int {
        state.beginSelect()
    }

    /// 一笔回包对号入座 —— 迟到的旧响应不覆盖更新的选择。
    func settle(generation: Int, selected: ModelSelection) {
        state.settle(generation: generation, selected: selected)
        displayed = state.displayed
    }
}
