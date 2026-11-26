/**
 * 事件序号 → 会话层级坐标。只认四种边界事件，其余事件靠「最近一个边界」继承。
 *
 * 为什么不能只看事件自己的 `turn`/`step` 字段：普通事件常常只带其中一个（工具结果只带 step），
 * 而窗口可以从一轮中间开始（往回翻），这时「继承上一个边界」是唯一能给出位置的办法。
 * `turn` 显式为 `null` 的事件不继承 —— 它是会话级事实，强行塞进某一轮会画出错位的行。
 */
import Foundation

struct LocationIndex: Equatable {

    /// 只比结果（`turns` / `coordinates`）。`drafts` 是派生它的过程量 ——
    /// 把它算进值相等会让「同一份位置」因为累积方式不同而不相等。
    static func == (left: LocationIndex, right: LocationIndex) -> Bool {
        left.turns == right.turns && left.coordinates == right.coordinates
    }

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

    /// 扫描状态：跨段传递。前插时「插入段的末状态」就是「原窗口那一段」的起点 ——
    /// 少了它，原来那条「非边界事件继承最近一个边界」的规则就断了。
    struct ScanState: Equatable {
        var turn: Int?
        var step: Int?

        static let initial = ScanState(turn: nil, step: nil)
    }

    private(set) var turns: [Int: TurnLocation] = [:]
    private var coordinates: [EventOrder: Coordinates] = [:]
    /// 轮次草稿。**由扫描累积、由 `mergeTouched` 落成 `turns`** —— 前者是过程量，后者是结果。
    private var drafts: [Int: TurnDraft] = [:]

    /// 累计扫过多少条事件。**为判据而留的读数**：它证明前插只碰了「插入段 + 污染区间」。
    private(set) var scannedCount = 0

    /// 上一次 `advance` 里**值真的变了的**坐标（新写入的不算）。前插用它判断
    /// 「污染区间是否改写了既有坐标」—— 改了就说明有老槽位要跟着回填。
    private(set) var changedOrders: Set<EventOrder> = []

    /// 重算整段窗口。`events` 必须按 `order` 升序 —— 排序是调用方的责任，
    /// 这里再排一次就等于把「谁负责顺序」写成两处。
    mutating func rebuild(_ events: [AssemblyEvent]) {
        coordinates = [:]
        drafts = [:]
        _ = advance(events, from: .initial)
        // 整份重建可能缩窗：不再出现的轮次要清掉（前插只加不减，这条只在重建时起作用）。
        let live = Set(drafts.keys)
        turns = turns.filter { live.contains($0.key) }
    }

    /// 扫一段并给出段末状态。内部把坐标写进表、把草稿并进 `drafts`，
    /// 再把**这一段碰到的轮次**重新落成 `TurnLocation` —— 没碰到的轮次保持原实例，
    /// 「前插只增不改」那条判据靠的就是这一点。
    ///
    /// 前插调用两次：先扫插入段（`from: .initial`），再以返回值为起点扫污染区间。
    @discardableResult
    mutating func advance(_ events: [AssemblyEvent], from state: ScanState) -> ScanState {
        var currentTurn = state.turn
        var currentStep = state.step
        var touched: Set<Int> = []
        var changed: Set<EventOrder> = []

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

            let resolved = Coordinates(turn: turn, step: step)
            if let previous = coordinates[event.order], previous != resolved {
                changed.insert(event.order)
            }
            coordinates[event.order] = resolved
            if let turn {
                turnDraft(&drafts, turn: turn, order: event.order)
                touched.insert(turn)
            }
            if let turn, let step {
                stepDraft(&drafts, turn: turn, step: step, order: event.order)
            }

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

        scannedCount += events.count
        changedOrders = changed
        mergeTouched(touched)
        return ScanState(turn: currentTurn, step: currentStep)
    }

    /// 把这些轮次的草稿落成 `TurnLocation`。同值给**同一个实例** —— 否则「前插只增不改」
    /// 那条判据会因为引用不同而误报（它比较的就是值相等）。
    private mutating func mergeTouched(_ numbers: Set<Int>) {
        var stable = turns
        for number in numbers {
            guard let draft = drafts[number] else { continue }
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
            let value = TurnLocation(
                turn: draft.turn,
                status: draft.endOrder != nil ? .closed : (draft.startOrder == nil ? .unknown : .open),
                startOrder: draft.startOrder,
                endOrder: draft.endOrder,
                endTime: draft.endTime,
                steps: steps
            )
            stable[number] = stable[number] == value ? stable[number]! : value
        }
        turns = stable
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
