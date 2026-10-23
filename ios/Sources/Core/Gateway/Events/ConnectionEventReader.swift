import Foundation

/**
 * 一帧的判读结论：它是什么，以及这条流接下来怎么办。
 *
 * 形状与 `StreamReading` 同构（同样是「内容 + 建成 + 动作」三件），但**值域更窄**：这条流只有
 * `ready` / `emit` / `session-list` 三种内容。窄是它的判据 —— 事件流不重放，没有窗口、水位、
 * 未定稿帧，判读器若「顺手」认识它们，那些分支就永远不会被上游走过，只会成为下一次误判的入口。
 */
struct ConnectionEventReading {

    /// 这一帧是什么。
    enum Content: Equatable {
        /// 源此刻的代次：每次上游重建后加一；`nil` = 源此刻没有活的代次。
        case ready(generation: Int?)
        /// 一条转发事件：名字与参数原样。
        case emit(name: String, args: JSONValue)
        /// 会话列表的一条增量。网关把上游那四类事件翻成它，所以这里只认自己的形状。
        case sessionList(SessionListChange)
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
        case .refused:
            // 事件流的拒绝都是终态：`unknown-op` 是这台网关不认 events（版本旧），
            // `internal-error` 是网关装配漏了源 —— 再开一条只会再收一次同样的拒绝。
            // 注意 `.stop` 在连接层的含义是**收起这一条流**，连接不动。
            return .stop
        case .ready, .emit, .sessionList, .ignored:
            return .keep
        }
    }
}

/**
 * 把一帧线上文本判成 `ConnectionEventReading` —— 纯函数，不碰 socket、不持状态。
 *
 * 两种流的内容不同：会话流一帧可以是打开帧、事件、未定稿帧、占用读数；这条流只有 `ready`、
 * `emit` 与 `session-list`。窄值域是判据的一部分 —— 不认识的形状在这里一律丢弃，而不是猜
 * 一个近似的分支。
 *
 * 判据与网关 `remote/stream.ts` 的 `pumpEvents` 逐条对齐（两端协定的订阅流一节）：
 *
 * | 输入 | 判成 | 判据 |
 * |---|---|---|
 * | `item`，载荷 `kind` 是 `ready` | 代次 | `generation` 读得出就带上，读不出就是 `nil`（不补数） |
 * | `item`，载荷 `kind` 是 `emit` | 一条事件 | `event` 必须是字符串；`args` 原样，缺席即空列表 |
 * | `item`，`kind` 是 `session-list` | 列表增量 | 交给 `SessionListChange.decode`，认不出丢弃 |
 * | `item`，别的 `kind` / 没有 `kind` | 认不出 | 丢弃 —— 这条流不重放，只有读不出才丢 |
 * | `error` | 拒绝 | 载荷是 `{code, message}` |
 * | `end` | 收尾 | —— |
 * | 别的（含 `approval`） | 认不出 | 审批不走这条流：它是连接级广播，由无编号帧的收货人接 |
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
            case "session-list":
                // 形状判定的正身在 `SessionListChange.decode`（那里有它自己的判据）——
                // 这一跳只把「这条流的一种货物」接到那个类型上，不复制任何一条规则。
                guard let change = payload["change"].flatMap(SessionListChange.decode) else {
                    // 留痕：网关加了第五种 kind 时，这里没有分支可走，现场只剩这一行。
                    Log.warn(Log.Module.session,
                             "dropped a session-list change this build does not know")
                    return ConnectionEventReading(content: .ignored)
                }
                return ConnectionEventReading(content: .sessionList(change))
            default:
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
