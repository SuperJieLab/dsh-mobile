/**
 * 瞬态帧通道 —— 打字机流的独立状态机。
 *
 * ## 为什么不进镜像
 *
 * 瞬态帧（`assistant-stream`）**没有 `seq`**（上游契约如此），只有 attemptId /
 * revision / index —— 它们不进水位体系：推进游标等于把「没落盘的东西」当成了
 * 「已读到的位置」。所以它有自己的通道、自己的校验，与 `SessionMirror` 平行，
 * 互不触碰（docs/plans/M2-realtime-transient.md §3.4）。
 *
 * ## 校验什么
 *
 * - `revision`：一个 attempt 的代次。断号说明这一段的基线已经丢了 —— 后续
 *   chunk 是**增量**的，干等只会残缺，唯一正确的动作是**重开流取新基线**
 *   （新 opening 的 `assistantStream` 带已累积内容）。这与上游「断号即重连」
 *   （`transport.ts`）同构。
 * - `index`：chunk 的稠密位置。同样断号即 broken。
 * - `end`：`outcome.kind == "committed"` 时内容已作为持久事件进日志
 *   （事件帧会自然把它并进镜像），瞬态副本就此清场。
 *
 * ## 文本从哪来
 *
 * chunk 是上游模型流的 JSON（`StreamChunk`，实测 `llm/src/types.ts:424`）：
 * 打字机只拼 `type == "text-delta"` 的 `.text`；reasoning / tool-call / 块
 * 边界不属于对话文本，原样跳过 —— 与 `SessionEvent.displayMessage` 的取舍
 * 同一条显示规则。
 *
 * 不碰网络、不碰 UI：与 `SessionMirror` 一样，能被 iOS target 编译，也能被
 * `swiftc` 编成 macOS 命令行程序跑断言。
 */

/// opening 里带的瞬态基线（上游 `SessionAssistantStreamBaseline`，形状见
/// `session-controller/src/types.ts:457-471` —— 本文件只声明用到的字段）。
struct TransientBaseline {
    let revision: Int
    /// 进行中的 attempt 的已累积文本与下一个 chunk 位置；没有进行中的 attempt 就是 `nil`。
    let active: Active?

    struct Active {
        let revision: Int
        let nextIndex: Int
        /// 基线里已累积的 chunk 序列（原样的 JSON）。
        let stream: [JSONValue]
    }
}

/// 一条瞬态帧进入通道后的判定。
enum TransientVerdict: Equatable {
    /// 正常消化（追加、开始、结束都算）。
    case consumed
    /// 流正常结束（内容已 commit 进日志或被放弃）。镜像稍后会收到持久事件。
    case ended
    /// revision / index 断号 —— 调用方必须重开流取新基线。
    case broken
}

/// 一个会话的瞬态通道。**文本只能由 `apply` 系列方法推进**，与镜像同一条纪律。
struct TransientChannel {
    /// 当前打字机文本（只含 `text-delta` 的拼接）。
    private(set) var text = ""

    /// 当前 attempt 的 revision；没有进行中的 attempt 就是 `nil`。
    private var revision: Int?

    /// 下一个 chunk 应该带的 `index`。
    private var nextIndex = 0

    /// 有没有进行中的 attempt。
    private var active = false

    /// 是否有正在显示的瞬态内容。
    var isLive: Bool { active }

    /// 用 opening 的基线恢复（重开流、冷进入都会走这里）。**替换**整个瞬态状态 ——
    /// 基线是服务端此刻的权威，与镜像的 `open(with:)` 同一条规则。
    mutating func apply(baseline: TransientBaseline) {
        revision = baseline.revision
        guard let activeAttempt = baseline.active else {
            active = false
            nextIndex = 0
            text = ""
            return
        }
        active = true
        revision = activeAttempt.revision
        nextIndex = activeAttempt.nextIndex
        text = activeAttempt.stream.reduce(into: "") { result, chunk in
            if let delta = Self.textDelta(of: chunk) {
                result += delta
            }
        }
    }

    /// 消化一条瞬态帧。帧是上游 `SessionAssistantStreamFrame`（start/chunk/end），
    /// 这里用 `JSONValue` 原样收 —— 与事件体的容忍策略一致。
    mutating func apply(frame: JSONValue) -> TransientVerdict {
        switch frame["type"]?.string {
        case "start":
            guard let incoming = frame["revision"]?.int else { return .broken }
            revision = incoming
            nextIndex = 0
            text = ""
            active = true
            return .consumed

        case "chunk":
            guard active, let incoming = frame["revision"]?.int, let index = frame["index"]?.int else {
                return .broken
            }
            // 两个数都对上才收：基线丢了就是丢了，不自愈。
            guard incoming == revision, index == nextIndex else { return .broken }
            if let delta = Self.textDelta(of: frame["chunk"]) {
                text += delta
            }
            nextIndex += 1
            return .consumed

        case "end":
            // committed 的内容会以持久事件（`assistant/message`）从事件帧再来，
            // 瞬态副本到此退场。
            active = false
            revision = nil
            nextIndex = 0
            text = ""
            return .ended

        default:
            return .broken
        }
    }

    /// 从一个 chunk 的 JSON 里抽出对话文本；不是文本块就是 `nil`。
    private static func textDelta(of chunk: JSONValue?) -> String? {
        guard chunk?["type"]?.string == "text-delta" else { return nil }
        return chunk?["text"]?.string
    }
}

extension JSONValue {
    /// 拿一个整数字段；拿不到就是 `nil`。
    var int: Int? {
        if case .number(let value) = self, value == value.rounded(), value >= 0 { return Int(value) }
        return nil
    }
}
