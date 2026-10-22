/**
 * 列表行上那几枚标签：谁在、什么字、什么顺序。
 *
 * 收成纯值类型而不是直接画在视图里，是因为这一期唯二不能靠真机反复验的事 ——
 * 「运行态与待批能不能同现」与「三条待批与一条怎么区分」—— 只有在纯函数上才有断言。
 * 视图按返回值 `ForEach`，不再自己拼条件、也不自己排顺序。
 *
 * 两件事刻意不做：不读应答状态（`AnswerState`）—— 表里有条目 ⟺ 详情页里有一张卡，
 * 再读一份就是两个写者说同一件事；不带任何手势 —— 标记只承载「看见」，应答在详情页。
 */
import Foundation

/// 一行上的一个标签。顺序由 `of` 给：先运行态、后待批。
enum SessionRowChip: Equatable {

    /// 这个会话正在跑。
    case running
    /// 这个会话有 `count` 条审批等着（`count >= 1`，0 不构造）。
    case pending(count: Int)

    /// 标签上的字。
    ///
    /// 单条不带数字：单条是常态，而「待审批 1」里的 1 没有信息量；多条必须带 ——
    /// 否则三条与一条长得一样，用户会以为只等一条。
    var text: String {
        switch self {
        case .running:
            return "进行中"
        case .pending(let count):
            return count <= 1 ? "待审批" : "待审批 \(count)"
        }
    }

    /// 这一行该画哪几枚标签。
    ///
    /// - Parameters:
    ///   - running: 服务端说的运行态（`SessionSummary.running`）。
    ///   - pendingCount: 待答表里属于这个会话的条数（`ApprovalStore.pendingCount(in:)`）。
    /// - Returns: 按固定顺序排好的标签；两件事都为假时是空数组（行高不变）。
    static func of(running: Bool, pendingCount: Int) -> [SessionRowChip] {
        var chips: [SessionRowChip] = []
        if running { chips.append(.running) }
        if pendingCount > 0 { chips.append(.pending(count: pendingCount)) }
        return chips
    }
}
