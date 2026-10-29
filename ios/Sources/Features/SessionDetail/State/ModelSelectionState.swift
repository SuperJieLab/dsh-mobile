/**
 * 会话内「当前模型」的订阅更新状态机 —— 纯值类型，不碰网络、不 import SwiftUI。
 *
 * `model/selection` 与 `request/header` 两类事件后到覆盖先到；水位纪律与 `UsageState` 同款
 * （严格高 seq 胜，相等也丢）。回包代号不匹配即丢弃 —— 迟到的旧响应不覆盖更新的选择。
 */
import Foundation

struct ModelSelectionState: Equatable {
    /// 当前显示的选择。`nil` = 还不知道 —— 界面退到目录默认，不猜。
    private(set) var displayed: ModelSelection?

    /// 已吸收的最大事件 `seq`；严格高 seq 才推进。
    private(set) var lastSeq: Int?

    /// 本机发起过的最新选择代号。
    private var generation = 0

    /// 吸收 opening 基线：服务端从**全会话**投影算出的「下一轮用什么」，
    /// 比窗口内的推断更权威 —— 无条件落地。`nil` = 服务端不知道，不清旧值、不猜默认。
    mutating func absorb(baseline: ModelSelection?) {
        if let baseline { displayed = baseline }
    }

    /// 吸收一条流事件；返回是否推进了显示。不认识的类型静默忽略 ——
    /// 事件体原样透传，上游加事件不该让客户端崩。
    @discardableResult
    mutating func absorb(event: SessionEvent) -> Bool {
        // 水位纪律：旧 seq 是重放，同 seq 是重复，都不得倒退显示。
        if let lastSeq, event.seq <= lastSeq { return false }

        guard let selection = selection(in: event) else { return false }
        displayed = selection
        lastSeq = event.seq
        return true
    }

    /// 发起一次 `model-select`：取回本次的代号，回包时凭它对号。
    mutating func beginSelect() -> Int {
        generation += 1
        return generation
    }

    /// 一笔回包对号入座：代号仍是最新的才落地。返回是否被接受。
    @discardableResult
    mutating func settle(generation: Int, selected: ModelSelection) -> Bool {
        guard generation == self.generation else { return false }
        displayed = selected
        return true
    }

    // MARK: - 事件形状（照上游投影的形状逐字核实过）

    /// 从两类事件里取出模型选择；两类之外是 `nil`。
    private func selection(in event: SessionEvent) -> ModelSelection? {
        switch event.type {
        case "model/selection":
            // data 就是选择本身 —— 上游 append 这条事件时把选择平铺在载荷上。
            return ModelSelection(
                provider: event.data["provider"]?.string ?? "",
                model: event.data["model"]?.string ?? "",
                reasoningEffort: event.data["reasoningEffort"]?.string
            )
        case "request/header":
            // 模型在 data.header.config 下；上游自己把 reasoningEffort 收成 String。
            let config = event.data["header"]?["config"]
            guard let provider = config?["provider"]?.string,
                  let model = config?["model"]?.string else { return nil }
            return ModelSelection(provider: provider, model: model, reasoningEffort: config?["reasoningEffort"]?.string)
        default:
            return nil
        }
    }
}
