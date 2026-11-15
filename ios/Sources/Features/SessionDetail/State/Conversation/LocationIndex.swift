/**
 * 事件序号 → 会话层级坐标。只认四种边界事件，其余事件靠「最近一个边界」继承。
 *
 * 为什么不能只看事件自己的 `turn`/`step` 字段：普通事件常常只带其中一个（工具结果只带 step），
 * 而窗口可以从一轮中间开始（往回翻），这时「继承上一个边界」是唯一能给出位置的办法。
 * `turn` 显式为 `null` 的事件不继承 —— 它是会话级事实，强行塞进某一轮会画出错位的行。
 */
import Foundation

struct LocationIndex: Equatable {

    struct Coordinates: Equatable {
        var turn: Int?
        var step: Int?
    }

    private struct StepDraft {
        var step: Int
        var firstOrder: EventOrder
        var startOrder: EventOrder?
        var endOrder: EventOrder?
        var endTime: Double?
    }

    private struct TurnDraft {
        var turn: Int
        var firstOrder: EventOrder
        var startOrder: EventOrder?
        var endOrder: EventOrder?
        var endTime: Double?
        var steps: [Int: StepDraft] = [:]
    }

    private(set) var turns: [Int: TurnLocation] = [:]
    private var coordinates: [EventOrder: Coordinates] = [:]

    /// 重算整段窗口。`events` 必须按 `order` 升序 —— 排序是调用方的责任，
    /// 这里再排一次就等于把「谁负责顺序」写成两处。
    mutating func rebuild(_ events: [AssemblyEvent]) {
        var drafts: [Int: TurnDraft] = [:]
        var resolved: [EventOrder: Coordinates] = [:]
        var currentTurn: Int?
        var currentStep: Int?

        for event in events {
            let explicit = Self.payloadCoordinates(event)

            switch event.type {
            case "turn/start":
                currentTurn = event.turn
                currentStep = nil
            case "step/start":
                currentTurn = event.turn
                currentStep = event.step
            default:
                break
            }

            if !event.isSessionScoped, let turn = explicit.turn {
                if currentTurn != turn { currentStep = nil }
                currentTurn = turn
                if let step = explicit.step { currentStep = step }
            }

            let turn = event.isSessionScoped ? nil : (explicit.turn ?? currentTurn)
            // 轮次边界事件本身不属于任何一步：它描述的是「这一轮的开/关」。
            let step: Int? = (event.isSessionScoped || event.type == "turn/start" || event.type == "turn/end")
                ? nil
                : (explicit.step ?? (turn == currentTurn ? currentStep : nil))

            resolved[event.order] = Coordinates(turn: turn, step: step)
            if let turn { turnDraft(&drafts, turn: turn, order: event.order) }
            if let turn, let step { stepDraft(&drafts, turn: turn, step: step, order: event.order) }

            switch event.type {
            case "turn/start":
                if let turn { setTurnStart(&drafts, turn: turn, order: event.order) }
            case "turn/end":
                if let turn { setTurnEnd(&drafts, turn: turn, order: event.order, time: event.time) }
            case "step/start":
                if let turn, let step { setStepStart(&drafts, turn: turn, step: step, order: event.order) }
            case "step/end":
                if let turn, let step { setStepEnd(&drafts, turn: turn, step: step, order: event.order, time: event.time) }
            default:
                break
            }

            if event.type == "step/end", currentTurn == event.turn, currentStep == event.step {
                currentStep = nil
            }
            if event.type == "turn/end", currentTurn == event.turn {
                currentTurn = nil
                currentStep = nil
            }
        }

        let ordered = drafts.values.sorted { $0.firstOrder < $1.firstOrder }
        var nextTurns: [Int: TurnLocation] = [:]
        for draft in ordered {
            let steps = draft.steps.values
                .sorted { $0.firstOrder < $1.firstOrder }
                .map { step in
                    StepLocation(
                        turn: draft.turn,
                        step: step.step,
                        status: step.endOrder != nil ? .closed : (step.startOrder == nil ? .unknown : .open),
                        startOrder: step.startOrder,
                        endOrder: step.endOrder,
                        endTime: step.endTime
                    )
                }
            nextTurns[draft.turn] = TurnLocation(
                turn: draft.turn,
                status: draft.endOrder != nil ? .closed : (draft.startOrder == nil ? .unknown : .open),
                startOrder: draft.startOrder,
                endOrder: draft.endOrder,
                endTime: draft.endTime,
                steps: steps
            )
        }

        // 位置值逐条重算：坐标本身没变时也要给出同一个 `TurnLocation` 实例，
        // 否则「前插只增不改」那条判据会因为引用不同而误报。
        let previous = turns
        var stable: [Int: TurnLocation] = [:]
        for (number, value) in nextTurns {
            stable[number] = previous[number] == value ? previous[number]! : value
        }

        turns = stable
        coordinates = resolved
    }

    func locationOf(_ event: AssemblyEvent) -> ConversationLocation {
        resolve(coordinates[event.order])
    }

    private func resolve(_ coordinates: Coordinates?) -> ConversationLocation {
        guard let coordinates, let number = coordinates.turn else { return .session }
        guard let turn = turns[number] else { return .unresolved }
        guard let stepNumber = coordinates.step else { return .turn(turn) }
        guard let step = turn.steps.first(where: { $0.step == stepNumber }) else { return .turn(turn) }
        return .step(turn, step)
    }

    private struct PayloadCoordinates {
        var turn: Int?
        var step: Int?
    }

    private static func payloadCoordinates(_ event: AssemblyEvent) -> PayloadCoordinates {
        // `turn` 显式为 `null` 的情形由 `isSessionScoped` 处理；这里只取非负整数。
        PayloadCoordinates(turn: event.turn, step: event.step)
    }

    private func turnDraft(_ drafts: inout [Int: TurnDraft], turn: Int, order: EventOrder) {
        if var draft = drafts[turn] {
            draft.firstOrder = min(draft.firstOrder, order)
            drafts[turn] = draft
        } else {
            drafts[turn] = TurnDraft(turn: turn, firstOrder: order)
        }
    }

    private func stepDraft(_ drafts: inout [Int: TurnDraft], turn: Int, step: Int, order: EventOrder) {
        turnDraft(&drafts, turn: turn, order: order)
        guard var owner = drafts[turn] else { return }
        if var draft = owner.steps[step] {
            draft.firstOrder = min(draft.firstOrder, order)
            owner.steps[step] = draft
        } else {
            owner.steps[step] = StepDraft(step: step, firstOrder: order)
        }
        drafts[turn] = owner
    }

    private func setTurnStart(_ drafts: inout [Int: TurnDraft], turn: Int, order: EventOrder) {
        guard var draft = drafts[turn] else { return }
        draft.startOrder = order
        drafts[turn] = draft
    }

    private func setTurnEnd(_ drafts: inout [Int: TurnDraft], turn: Int, order: EventOrder, time: Double) {
        guard var draft = drafts[turn] else { return }
        draft.endOrder = order
        draft.endTime = time
        drafts[turn] = draft
    }

    private func setStepStart(_ drafts: inout [Int: TurnDraft], turn: Int, step: Int, order: EventOrder) {
        guard var owner = drafts[turn], var draft = owner.steps[step] else { return }
        draft.startOrder = order
        owner.steps[step] = draft
        drafts[turn] = owner
    }

    private func setStepEnd(_ drafts: inout [Int: TurnDraft], turn: Int, step: Int, order: EventOrder, time: Double) {
        guard var owner = drafts[turn], var draft = owner.steps[step] else { return }
        draft.endOrder = order
        draft.endTime = time
        owner.steps[step] = draft
        drafts[turn] = owner
    }
}
