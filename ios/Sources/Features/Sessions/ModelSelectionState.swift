/**
 * 会话内「当前模型」的跟随更新状态机 —— 一台纯状态机（M7 决定 2 / 决定 4）。
 *
 * 不 import SwiftUI / UIKit、不碰网络：输入是 opening 基线、流事件与 select 回包，
 * 输出是当前显示的选择。更新规则是上游投影（`model-selection-projection.js` 的
 * `applyModelSelectionProjection`）的**窗口内简化版**：
 *
 * - `model/selection` 事件 → 显示该选择（有人换了选择）
 * - `request/header` 事件 → 显示 `data.header.config` 里的模型（本轮实际用的）
 * - 两类事件**后到覆盖先到**：选择没被兑现时如实显示落地值，不装作总成立（V2）
 * - 水位纪律与 M6 吸收器同款：**严格高 seq 胜，相等也丢** —— 重放不倒退（V3）
 *
 * 简化掉的是上游的 `{lastUsed, pending}` 对账：窗口起点由 opening 基线封口
 * （服务端从全会话投影算好，决定 1），窗口内的增量客户端有全部输入，无需补全量状态。
 * 上游若给投影加第三种事件，这里不会自动跟上 —— 代价已登记（Plan §3.1 决定 2）。
 *
 * generation 守卫照上游客户端同款纪律（`ui-model-selection/lib/client.js:210-243`
 * 「Latest selection operation wins」）：每次发起 `model-select` 递增代号，
 * 回包时代号不匹配即丢弃 —— 迟到的旧响应绝不覆盖更新的选择（V4）。
 *
 * 与 `SessionMirror` 同一形态：能被 iOS target 编译，也能被 `swiftc`
 * 编成 macOS 命令行程序跑断言（`ios/tests/run-model.sh`）。
 */
import Foundation

struct ModelSelectionState: Equatable {
    /// 当前显示的选择。`nil` = 还不知道 —— 界面退到目录默认，不猜（决定 7）。
    private(set) var displayed: ModelSelection?

    /// 已吸收的最大事件 `seq`；严格高 seq 才推进。
    private(set) var lastSeq: Int?

    /// 本机发起过的最新选择代号。
    private var generation = 0

    /// 吸收 opening 基线（决定 1）：服务端从**全会话**投影算出的「下一轮用什么」，
    /// 比窗口内的推断更权威 —— 无条件落地。`nil` = 服务端不知道，不清旧值、不猜默认。
    mutating func absorb(baseline: ModelSelection?) {
        if let baseline { displayed = baseline }
    }

    /// 吸收一条流事件；返回是否推进了显示。不认识的类型静默忽略 ——
    /// 事件体原样透传，上游加事件不该让客户端崩。
    @discardableResult
    mutating func absorb(event: SessionEvent) -> Bool {
        // 水位纪律（V3）：旧 seq 是重放，同 seq 是重复，都不得倒退显示。
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

    /// 一笔回包对号入座：代号仍是最新的才落地。返回是否被接受（V4）。
    @discardableResult
    mutating func settle(generation: Int, selected: ModelSelection) -> Bool {
        guard generation == self.generation else { return false }
        displayed = selected
        return true
    }

    // MARK: - 事件形状（逐字核实：model-selection-projection.js:31-44）

    /// 从两类事件里取出模型选择；两类之外是 `nil`。
    private func selection(in event: SessionEvent) -> ModelSelection? {
        switch event.type {
        case "model/selection":
            // data 就是选择本身（agent.js:350 append 的载荷）。
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
