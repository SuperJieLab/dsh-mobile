import Foundation

/**
 * 一帧的判读结论：它是什么，以及这条流接下来怎么办。
 * 形状与 `StreamReading` 同构，但**值域更窄**：只有控制结局、转发事件与具名货物三类。
 */
struct EventReading {

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

    /// 这一帧是否意味着「这条流从此刻建成」。只有 `ready` 成立：`emit` 若能建成，
    /// 这条流会在源还没有代次时被当成开成了，于是开流超时撤防、退避归零。
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
            // 按「重试之后结果会不会不同」分，不按错得多严重分：源没就绪、
            // 网关内部错都可能一次就好；
            // 「这台网关不认 events」重试一万次也一样。
            return Self.retryableCodes.contains(failure.code) ? .retry : .stop
        case .ready, .emit, .cargo, .ignored:
            return .keep
        }
    }

    /// 重试之后结果**可能不同**的拒绝码。依据只有一句：再开一条同样的流，上游的答复会不会变。
    /// `source-unavailable` 与 `internal-error` 会变；`unknown-op`、`unauthorized` 不会。
    static let retryableCodes: Set<String> = [
        GatewayErrorCode.sourceUnavailable.rawValue,
        GatewayErrorCode.internalError.rawValue,
    ]
}

/**
 * 把一帧已解好的入站帧判成 `EventReading` —— 纯函数，不碰 socket、不持状态。
 * 吃外壳与已解好的载荷：`kind` 那一支的载荷是任意 JSON（`args` 是上游 `emit` 的参数，
 * 形状随货物变），所以它在这一层仍是 `JSONValue`，不做强类型。
 */
enum EventReader {

    static func read(_ frame: InboundFrame) -> EventReading {
        switch frame.type {
        case "item":
            guard case .item(.connectionItem(let payload))? = frame.payload,
                  let kind = payload["kind"]?.string else {
                return EventReading(content: .ignored)
            }
            switch kind {
            case "ready":
                // `generation` 读不出（缺席、非整数、负数）一律 `nil`：
                // 宁可说不知道，也不补一个看起来正常的数。
                return EventReading(content: .ready(generation: payload["generation"]?.int))
            case "emit":
                guard let name = payload["event"]?.string else {
                    // 名字读不出就无从分派给任何消费方 —— 丢弃。
                    return EventReading(content: .ignored)
                }
                // `args` 缺席是正常的：上游 `emit(event)` 不带参数时，网关那份
                // `JSON.stringify` 会把 `undefined` 丢掉。
                return EventReading(content: .emit(name: name, args: payload["args"] ?? .array([])))
            case "session-list", "waterfall", "cancel":
                // 三条具名货物：kind 名与载荷原样交出。这一层只分类，不解释货物内容。
                return EventReading(content: .cargo(type: kind, payload: payload))
            default:
                // 留痕要带**名字**：新货物被这一版丢弃时现场只剩这一行，
                // 不带名字就分不出「网关加了货物」与「这条流坏了」。
                Log.warn(Log.Module.session,
                         "dropped an item kind this build does not know: \(kind)")
                return EventReading(content: .ignored)
            }

        case "error":
            guard case .refused(let failure)? = frame.payload else {
                // 解不出载荷的 error 帧已在解码层兜成 internal-error，正常走不到这里。
                return EventReading(content: .refused(GatewayFailure(
                    code: GatewayErrorCode.internalError.rawValue, message: ""
                )))
            }
            return EventReading(content: .refused(failure))

        case "end":
            return EventReading(content: .ended)

        default:
            return EventReading(content: .ignored)
        }
    }
}
