/**
 * 列表流的帧判读：网关这一条流上只会有三类 item —— `ready` 与 `session-list`，
 * 加上协议级的 `error` / `end`。
 *
 * 与审批那条同一个理由自带 reading 类型：共用 `cargo(type:)` 会让货物名在 reader 与收端
 * 各认一次，而那一份重复漂了不会有编译错误。
 *
 * **`ready` 不携带集合**，这是这条流与审批流最要紧的区别：就绪只说明「服务端开好了这条流、
 * 源此刻是哪一代」，客户端要的列表自己另读（`list-sessions`）。推一份全量基线会让这条流
 * 多背一种帧，换来的只是省一次 HTTP。
 */
import Foundation

struct SessionListReading {

    /// 这一帧是什么。
    enum Content: Equatable {
        /// 源此刻的代次：每次上游重建后加一；`nil` = 源此刻没有活的代次。
        /// 客户端收到它就重读一次列表 —— 断线期间的变化不补发。
        case ready(generation: Int?)
        /// 一条列表增量，载荷原样（含 `kind` 与 `change`）。四支 change 的解释归消费方。
        case change(JSONValue)
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
    /// 它讲的是**开流握手完成**（流层据此退避归零、关掉开流超时），不是「列表可信」。
    /// 后者由 `SessionListState` 按自己的语义答：收到 `ready` 就重拉一次。
    var establishes: Bool {
        if case .ready = content { return true }
        return false
    }

    /// 这条流接下来该怎么办。默认什么都不做。
    var next: StreamNext {
        switch content {
        case .ended:
            return .reopen
        case let .refused(failure):
            return failure.isRetryable ? .retry : .stop
        case .ready, .change, .ignored:
            return .keep
        }
    }
}

/**
 * 把一帧已解好的入站帧判成 `SessionListReading` —— 纯函数，不碰 socket、不持状态。
 */
enum SessionListStreamReader {

    static func read(_ frame: InboundFrame) -> SessionListReading {
        switch frame.type {
        case "item":
            guard case .item(.connectionItem(let payload))? = frame.payload,
                  let kind = payload["kind"]?.string else {
                return SessionListReading(content: .ignored)
            }
            switch kind {
            case "ready":
                // `generation` 读不出（缺席、非整数、负数）一律 `nil`：
                // 宁可说不知道，也不补一个看起来正常的数。
                return SessionListReading(content: .ready(generation: payload["generation"]?.int))
            case "session-list":
                return SessionListReading(content: .change(payload))
            default:
                // 留痕要带**名字**：别的流的货物漏到这条流上时，现场只剩这一行；
                // 不带名字就分不出「网关推错了流」与「这条流坏了」。
                Log.warn(Log.Module.session,
                         "dropped an item kind the session-list stream does not carry: \(kind)")
                return SessionListReading(content: .ignored)
            }

        case "error":
            guard case .refused(let failure)? = frame.payload else {
                return SessionListReading(content: .refused(GatewayFailure(
                    code: GatewayErrorCode.internalError.rawValue, message: ""
                )))
            }
            return SessionListReading(content: .refused(failure))

        case "end":
            return SessionListReading(content: .ended)

        default:
            return SessionListReading(content: .ignored)
        }
    }
}
