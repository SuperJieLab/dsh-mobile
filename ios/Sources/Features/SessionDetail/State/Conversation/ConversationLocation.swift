/**
 * 一个事件落在会话层级里的哪个位置 —— 会话级 / 某一轮 / 某一轮里的某一步 / 定不下来。
 *
 * 位置来自边界事件（`turn/start`、`step/end` …）而不是来自事件自己的字段：同一轮里的普通事件
 * 可以不带宽高信息，靠「最近一个边界」继承。定义靠它决定「这一段属于哪个槽位」，
 * 以及「这一轮/这一步已经关上了吗」—— 后者是判「中断」的唯一依据。
 */
import Foundation

/// 一个事件在排序上的位置（`AssemblyEvent.order`）。允许小数。
typealias EventOrder = Double

/// 一轮或一步的开关状态。`unknown` = 边界事件不在窗口里（往回翻时窗口会从中间切开）。
enum BoundaryStatus: Equatable {
    case open
    case closed
    case unknown
}

struct StepLocation: Equatable {
    let turn: Int
    let step: Int
    let status: BoundaryStatus
    let startOrder: EventOrder?
    let endOrder: EventOrder?
    let endTime: Double?
}

struct TurnLocation: Equatable {
    let turn: Int
    let status: BoundaryStatus
    let startOrder: EventOrder?
    let endOrder: EventOrder?
    let endTime: Double?
    let steps: [StepLocation]
}

enum ConversationLocation: Equatable {
    /// 会话级事实：不属于任何一轮。
    case session
    case turn(TurnLocation)
    case step(TurnLocation, StepLocation)
    /// 有轮次号，但那一轮不在当前窗口里 —— 位置没解析出来，不是「没有位置」。
    case unresolved

    var turnNumber: Int? {
        switch self {
        case .turn(let turn), .step(let turn, _): return turn.turn
        case .session, .unresolved: return nil
        }
    }

    var stepNumber: Int? {
        if case .step(_, let step) = self { return step.step }
        return nil
    }

    /// 这一段所在的槽位已经关上了吗 —— 关在哪个序号、哪个时刻。
    ///
    /// 先看 step 再退到 turn：一步关上了就够，不必等整轮关。
    /// 两处都还在开着（或边界不在窗口里）⇒ 不知道，不猜。
    var closedBoundary: Boundary? {
        switch self {
        case .step(_, let step):
            if step.status == .closed, let order = step.endOrder, let time = step.endTime {
                return Boundary(order: order, time: time)
            }
            return turnClosedBoundary
        case .turn:
            return turnClosedBoundary
        case .session, .unresolved:
            return nil
        }
    }

    private var turnClosedBoundary: Boundary? {
        guard let turn = turnLocation, turn.status == .closed,
              let order = turn.endOrder, let time = turn.endTime else { return nil }
        return Boundary(order: order, time: time)
    }

    var turnLocation: TurnLocation? {
        switch self {
        case .turn(let turn), .step(let turn, _): return turn
        case .session, .unresolved: return nil
        }
    }
}

/// 边界事件在窗口里的位置。
struct Boundary: Equatable {
    let order: EventOrder
    let time: Double
}
