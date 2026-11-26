/**
 * 未定稿帧通道 —— 校验 revision/index，并把帧翻成**带小数序号的事件**交给组装引擎。
 *
 * 未定稿内容在定稿前没有 `seq`（水位体系只认持久事件），但它必须排进同一个有序列表：
 * 序号取 `cursor + 1 - 1/(n+1)`，落在「最后一条持久事件之后、下一条之前」，且不占整数空间。
 * 用 `1/(n+1)` 而不是每次 `+0.1`：后者第 10 个 chunk 就撞上 `cursor + 1`，越界到下一批事件之前。
 *
 * 每帧要求 `revision` 等于期望值、`index` 等于已累积块数；任一不满足即 `broken`
 * —— 增量已丢基线，唯一正确的动作是重开流取新基线。
 */
import Foundation

struct TransientChannel {

    /// `end` 帧的点名：这一轮收笔对应哪条持久事件。
    struct Settlement: Equatable {
        let attemptId: String
        /// 认领的序号；`nil` 表示这一轮被放弃（没有定稿事件可认）。
        let seq: Int?
        let eventType: String?
    }

    enum Result {
        /// 正常消化；带上要交给引擎的事件（`start` 与 `end` 不带）。
        case consumed([AssemblyEvent])
        case ended(Settlement)
        /// revision / index 断号 —— 调用方必须重开流取新基线。
        case broken
    }

    private struct Attempt {
        let attemptId: String
        let turn: Int
        let step: Int
    }

    private var attempt: Attempt?
    /// 下一帧应带的 revision（全局单调；`nil` 表示尚未见过任何基线或帧）。
    private var expectedRevision: Int?
    /// 当前 attempt 内下一个 chunk 的位置。
    private var nextChunkIndex = 0
    /// 当前 attempt 已经编了几个小数序号 —— 序号的小数部分靠它推进。
    private var transientInGap = 0

    /// 有没有进行中的 attempt。
    var isLive: Bool { attempt != nil }
    var liveAttemptId: String? { attempt?.attemptId }

    // MARK: - 诊断（只读快照，供日志；不进公开语义）

    var expectedRevisionDescription: Int? { expectedRevision }
    var nextIndexDescription: Int { nextChunkIndex }

    /// 用 opening 的基线恢复（重开流、冷进入都会走这里）。**替换**整个未定稿状态 ——
    /// 基线是服务端此刻的权威。返回基线里已累积内容对应的事件，交给引擎重放。
    mutating func apply(baseline: JSONValue, cursor: Int) -> [AssemblyEvent] {
        expectedRevision = (baseline["revision"]?.int ?? 0) + 1
        attempt = nil
        nextChunkIndex = 0
        transientInGap = 0

        guard let active = baseline["activeAttempt"] else { return [] }
        let live = Attempt(
            attemptId: active["attemptId"]?.string ?? "",
            turn: active["turn"]?.int ?? 0,
            step: active["step"]?.int ?? 0
        )
        attempt = live
        let accumulated = active["nextIndex"]?.int ?? 0
        nextChunkIndex = accumulated

        // 基线里的 `stream` 是**紧凑记录**，不是一条记录一个 chunk —— 先展开，
        // 再按 `nextIndex`（已累积的 chunk 数）截断。不展开就一条也画不出来。
        var events: [AssemblyEvent] = []
        for record in CompactStream.expand(active["stream"]?.array ?? []) where events.count < accumulated {
            transientInGap += 1
            events.append(event(for: record.chunk, of: live, time: record.time, cursor: cursor))
        }
        return events
    }

    /// 消化一条未定稿帧。
    mutating func apply(frame: JSONValue, cursor: Int) -> Result {
        let incoming = frame["revision"]?.int
        switch frame["type"]?.string {
        case "start":
            guard incoming != nil, incoming == expectedRevision,
                  let turn = frame["turn"]?.int, let step = frame["step"]?.int else { return .broken }
            expectedRevision! += 1
            attempt = Attempt(
                attemptId: frame["attemptId"]?.string ?? "",
                turn: turn,
                step: step
            )
            nextChunkIndex = 0
            transientInGap = 0
            return .consumed([])

        case "chunk":
            guard let live = attempt,
                  let revision = incoming,
                  let index = frame["index"]?.int else { return .broken }
            guard revision == expectedRevision, index == nextChunkIndex else { return .broken }
            transientInGap += 1
            let event = event(for: frame["chunk"], of: live, time: frame["time"]?.number ?? 0, cursor: cursor)
            expectedRevision! += 1
            nextChunkIndex += 1
            return .consumed([event])

        case "end":
            guard let live = attempt, incoming != nil, incoming == expectedRevision else { return .broken }
            expectedRevision! += 1
            attempt = nil
            nextChunkIndex = 0
            transientInGap = 0
            let outcome = frame["outcome"]
            // 被放弃的那一轮没有定稿事件可认 —— 交一个空 seq 让上层把草稿整批撤掉。
            guard outcome?["kind"]?.string == "committed" else {
                return .ended(Settlement(attemptId: live.attemptId, seq: nil, eventType: nil))
            }
            return .ended(Settlement(
                attemptId: live.attemptId,
                seq: outcome?["seq"]?.int,
                eventType: outcome?["eventType"]?.string
            ))

        default:
            return .broken
        }
    }

    private func event(for chunk: JSONValue?, of live: Attempt, time: Double, cursor: Int) -> AssemblyEvent {
        let order = Double(cursor) + 1 - 1 / Double(transientInGap + 1)
        let data = JSONValue.object([
            "attemptId": .string(live.attemptId),
            "turn": .number(Double(live.turn)),
            "step": .number(Double(live.step)),
            "chunk": chunk ?? .null,
        ])
        return AssemblyEvent(order: order, seq: nil, type: "assistant/live-chunk", time: time, data: data)
    }
}
