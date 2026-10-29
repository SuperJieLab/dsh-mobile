/**
 * 未定稿帧通道 —— 流式输出的独立状态机，与 `SessionMirror` 平行互不触碰。
 *
 * 未定稿帧没有 `seq`，不进水位体系。每帧要求 `revision` 等于期望值、`index` 等于已累积 chunk 数；
 * 任一不满足即 `broken`：后续 chunk 是增量、基线已丢，唯一正确的动作是重开流取新基线。
 */

/// opening 里带的未定稿基线（上游 `SessionAssistantStreamBaseline`）：revision 与
/// 进行中 attempt 的已累积内容 —— 本文件只声明用到的字段。
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

/// 一条未定稿帧进入通道后的判定。
enum TransientVerdict: Equatable {
    /// 正常消化（追加、开始、结束都算）。
    case consumed
    /// 流正常结束（内容已 commit 进日志或被放弃）。镜像稍后会收到持久事件。
    case ended
    /// revision / index 断号 —— 调用方必须重开流取新基线。
    case broken
}

/// 一个会话的未定稿通道。**文本只能由 `apply` 系列方法推进**，与镜像同一条纪律。
struct TransientChannel {
    /// 当前流式输出文本（只含 `text-delta` 的拼接）。
    private(set) var text = ""

    /// 下一帧应带的 revision（全局单调；`nil` 表示尚未见过任何基线或帧）。
    private var expectedRevision: Int?

    /// 当前 attempt 内下一个 chunk 的位置。
    private var nextChunkIndex = 0

    /// 有没有进行中的 attempt。
    private var active = false

    /// 是否有正在显示的未定稿内容。
    var isLive: Bool { active }

    // MARK: - 诊断（只读快照，供日志；不进公开语义）

    var expectedRevisionDescription: Int? { expectedRevision }
    var nextIndexDescription: Int { nextChunkIndex }

    /// 用 opening 的基线恢复（重开流、冷进入都会走这里）。**替换**整个未定稿状态 ——
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

    /// 消化一条未定稿帧。帧是上游 `SessionAssistantStreamFrame`（start/chunk/end），
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
            // 未定稿副本到此退场。
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
