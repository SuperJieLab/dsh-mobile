import Foundation

/**
 * 一帧的判读结论：它是什么，以及这条流接下来怎么办。
 *
 * 形状与 `StreamReading` 同构（同样是「内容 + 建成 + 动作」三件），但**值域更窄**：这条流只有
 * 控制结局（`ready` / `refused` / `ended` / `ignored`）、转发事件（`emit`）与具名货物三类。
 * 窄是它的判据 —— 事件流不重放，没有窗口、水位、未定稿帧，判读器若「顺手」认识它们，
 * 那些分支就永远不会被上游走过，只会成为下一次误判的入口。
 */
struct ConnectionEventReading {

    /// 这一帧是什么。
    enum Content: Equatable {
        /// 源此刻的代次：每次上游重建后加一；`nil` = 源此刻没有活的代次。
        case ready(generation: Int?)
        /// 一条转发事件：名字与参数原样。
        case emit(name: String, args: JSONValue)
        /// 一条具名货物：kind 名与整段载荷原样（含 `kind` 字段）。内容归各消费方解释。
        case cargo(type: String, payload: JSONValue)
        /// 流通道里的协议内拒绝。
        case refused(GatewayFailure)
        /// 流被服务端正常收尾。
        case ended
        /// 认不出、不属于本流、或解不出的那一部分 —— 丢弃，不重试也不猜。
        case ignored
    }

    let content: Content

    /// 这一帧是否意味着「这条流从此刻建成」。只有 `ready` 成立。
    ///
    /// 这一条不是形式：`emit` 若能建成，源还没有代次时心跳就会开始判死；而这条流的
    /// `ready` 是它的**全部状态**，建成与否只能由它说。
    var establishes: Bool {
        if case .ready = content { return true }
        return false
    }

    /// 这条流接下来该怎么办。默认什么都不做。
    var next: StreamNext {
        switch content {
        case .ended:
            // 服务端正常收尾：流还在、但不在工作了 ⇒ 同一条连接上换号重开。
            return .reopen
        case let .refused(failure):
            // 按「重试之后结果会不会不同」分，不按错得多严重分：源没就绪、网关内部错，
            // 都是一次重开就可能好；而「这台网关不认 events」重试一万次也一样。
            // `.retry` 在连接层的含义是**按流退避重开**，`.stop` 是收起这一条流 ——
            // 两者都不动连接。
            return Self.retryableCodes.contains(failure.code) ? .retry : .stop
        case .ready, .emit, .cargo, .ignored:
            return .keep
        }
    }

    /// 重试之后结果**可能不同**的拒绝码。
    ///
    /// 归类依据只有一句：再开一条同样的流，上游的答复会不会变。
    ///   - `source-unavailable`：这批待答项等源接上就能给 —— 会变
    ///   - `internal-error`：网关自己坏了，可能是瞬时的 —— 会变
    ///   - `unknown-op`（网关版本不认 events）、`unauthorized`：重开一万次也一样
    static let retryableCodes: Set<String> = [
        GatewayErrorCode.sourceUnavailable.rawValue,
        GatewayErrorCode.internalError.rawValue,
    ]
}

/**
 * 把一帧线上文本判成 `ConnectionEventReading` —— 纯函数，不碰 socket、不持状态。
 *
 * 两种流的内容不同：会话流一帧可以是打开帧、事件、未定稿帧、占用读数；这条流只有控制结局、
 * 转发事件与具名货物。窄值域是判据的一部分 —— 不认识的形状在这里一律丢弃，而不是猜一个
 * 近似的分支。
 *
 * 判据与网关 `remote/stream.ts` 的 `pumpEvents` 逐条对齐（两端协定的订阅流一节）：
 *
 * | 输入 | 判成 | 判据 |
 * |---|---|---|
 * | `item`，载荷 `kind` 是 `ready` | 代次 | `generation` 读得出就带上，读不出就是 `nil`（不补数） |
 * | `item`，载荷 `kind` 是 `emit` | 一条事件 | `event` 必须是字符串；`args` 原样，缺席即空列表 |
 * | `item`，`kind` 是三条货物名之一 | 具名货物 | kind 与载荷原样交出，解释住消费方 |
 * | `item`，有 `kind` 但词表里没有 | 认不出 | 丢弃并留带原值的 warn —— 版本错配的现场 |
 * | `item`，没有 `kind` / 没有载荷 | 认不出 | 丢弃（形状本身就不完整，没有名字可指认） |
 * | `error` | 拒绝 | 载荷是 `{code, message}`，动作由码决定（重试会不会变） |
 * | `end` | 收尾 | —— |
 * | 别的外壳 | 认不出 | 丢弃 |
 *
 * 只吃外壳、不要原始字节：载荷里没有 typed 结构要直解（`args` 是任意 JSON，`JSONValue`
 * 已原样拿在手上），与 `SessionStreamReader` 需要 `raw` 的理由不同。
 */
enum ConnectionEventReader {

    static func read(envelope: MuxServerEnvelope) -> ConnectionEventReading {
        switch envelope.type {
        case "item":
            guard let payload = envelope.payload, let kind = payload["kind"]?.string else {
                return ConnectionEventReading(content: .ignored)
            }
            switch kind {
            case "ready":
                // `generation` 读不出（缺席、非整数、负数）一律 `nil`：它是一个会被当成代次的
                // 数字，宁可说「不知道」，也不补一个看起来正常的数。
                return ConnectionEventReading(content: .ready(generation: payload["generation"]?.int))
            case "emit":
                guard let name = payload["event"]?.string else {
                    // 名字读不出就无从分派给任何消费方 —— 丢弃。
                    return ConnectionEventReading(content: .ignored)
                }
                // `args` 整段缺席是正常的：上游 `emit(event)` 不带参数时，网关那份
                // `JSON.stringify` 会把 `undefined` 字段丢掉。事件名已经说得清发生了什么。
                return ConnectionEventReading(content: .emit(name: name, args: payload["args"] ?? .array([])))
            case "session-list", "waterfall", "cancel":
                // 三条具名货物：kind 名与载荷原样交出。这一层只分类，不解释货物内容 ——
                // 怎么读、认不出怎么办（含无寻址的撤回），都住各自消费方。
                return ConnectionEventReading(content: .cargo(type: kind, payload: payload))
            default:
                // 留痕要带**名字**：手机与网关可能不同版本，新货物被这一版丢弃时现场只剩这一行
                // —— 不带名字就分不出「网关加了货物」与「这条流坏了」。
                Log.warn(Log.Module.session,
                         "dropped an item kind this build does not know: \(kind)")
                return ConnectionEventReading(content: .ignored)
            }

        case "error":
            let failure = GatewayFailure(
                code: envelope.payload?["code"]?.string ?? GatewayErrorCode.internalError.rawValue,
                message: envelope.payload?["message"]?.string ?? ""
            )
            return ConnectionEventReading(content: .refused(failure))

        case "end":
            return ConnectionEventReading(content: .ended)

        default:
            return ConnectionEventReading(content: .ignored)
        }
    }
}
