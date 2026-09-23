/**
 * 瞬态帧通道 —— 打字机流的独立状态机。
 *
 * 瞬态帧（`assistant-stream`）没有 `seq`，只有 attemptId / revision / index，不进水位体系：
 * 推进游标等于把「没落盘的东西」当成「已读到的位置」。所以它有自己的通道与校验，与
 * `SessionMirror` 平行互不触碰（docs/dev/plans/M2-realtime-transient.md §3.4）。
 *
 * `revision` 来自 agent 级全局单调计数器（`() => ++assistantStreamRevision`）：start / chunk /
 * end 每帧 +1、跨 attempt 连续，是断号校验的对象；`index` 是 attempt 内 chunk 的位置。校验即
 * 每帧 `revision` **正好等于**期望值（上帧 + 1，或基线 + 1），chunk 的 `index` 等于 attempt 内
 * 已累积的 chunk 数 —— 早期当成 attempt 恒定代次会第一帧就误判 broken（打字机不逐字）。
 *
 * 任一不满足 ⇒ `broken`：后续 chunk 是**增量**，基线已丢，唯一正确动作是**重开流取新基线**
 * （新 opening 的 `assistantStream` 带已累积内容），与上游「断号即重连」同构。
 *
 * chunk 是上游模型流的 JSON（`StreamChunk`，`llm/src/types.ts:424`）：只拼
 * `type == "text-delta"` 的 `.text`，其余原样跳过 ——
 * 与 `SessionEvent.displayMessage` 同一条显示规则。
 *
 * 不碰网络与 UI：能被 iOS target 编译，也能被 `swiftc` 编成 macOS 命令行程序跑断言。
 */

/// opening 里带的瞬态基线（上游 `SessionAssistantStreamBaseline`，形状见
/// `session-controller/src/types.ts:457-471` —— 本文件只声明用到的字段）。
struct TransientBaseline {
    /// 该基线**已用掉**的最后 revision —— 下一帧期望它 + 1。
    let revision: Int
    /// 进行中的 attempt 的已累积内容；没有进行中的 attempt 就是 `nil`。
    let active: Active?

    struct Active {
        /// attempt 内下一个 chunk 的位置。
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

    /// 下一帧应带的 revision（全局单调；`nil` 表示尚未见过任何基线或帧）。
    private var expectedRevision: Int?

    /// 当前 attempt 内下一个 chunk 的位置。
    private var nextChunkIndex = 0

    /// 有没有进行中的 attempt。
    private var active = false

    /// 是否有正在显示的瞬态内容。
    var isLive: Bool { active }

    // MARK: - 诊断（只读快照，供日志；不进公开语义）

    var expectedRevisionDescription: Int? { expectedRevision }
    var nextIndexDescription: Int { nextChunkIndex }

    /// 用 opening 的基线恢复（重开流、冷进入都会走这里）。**替换**整个瞬态状态 ——
    /// 基线是服务端此刻的权威，与镜像的 `open(with:)` 同一条规则。
    mutating func apply(baseline: TransientBaseline) {
        expectedRevision = baseline.revision + 1
        guard let attempt = baseline.active else {
            active = false
            nextChunkIndex = 0
            text = ""
            return
        }
        active = true
        nextChunkIndex = attempt.nextIndex
        text = attempt.stream.reduce(into: "") { result, chunk in
            if let delta = Self.textDelta(of: chunk) {
                result += delta
            }
        }
    }

    /// 消化一条瞬态帧。帧是上游 `SessionAssistantStreamFrame`（start/chunk/end），
    /// 这里用 `JSONValue` 原样收 —— 与事件体的容忍策略一致。
    mutating func apply(frame: JSONValue) -> TransientVerdict {
        let incoming = frame["revision"]?.int
        switch frame["type"]?.string {
        case "start":
            guard incoming != nil, incoming == expectedRevision else { return .broken }
            expectedRevision! += 1
            nextChunkIndex = 0
            text = ""
            active = true
            return .consumed

        case "chunk":
            guard active,
                  let revision = incoming,
                  let index = frame["index"]?.int else { return .broken }
            guard revision == expectedRevision, index == nextChunkIndex else { return .broken }
            if let delta = Self.textDelta(of: frame["chunk"]) {
                text += delta
            }
            expectedRevision! += 1
            nextChunkIndex += 1
            return .consumed

        case "end":
            guard incoming != nil, incoming == expectedRevision else { return .broken }
            expectedRevision! += 1
            // committed 的内容会以持久事件（`assistant/message`）从事件帧再来，
            // 瞬态副本到此退场。
            active = false
            nextChunkIndex = 0
            text = ""
            return .ended

        default:
            return .broken
        }
    }

    private static func textDelta(of chunk: JSONValue?) -> String? {
        guard chunk?["type"]?.string == "text-delta" else { return nil }
        return chunk?["text"]?.string
    }
}
