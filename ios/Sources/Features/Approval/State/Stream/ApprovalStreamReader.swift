/**
 * 审批流的帧判读：网关这一条流上只会有三类 item —— `ready`、`waterfall`、`cancel`。
 *
 * 值域窄是刻意的：认得出「这一类不归我」比认得出所有货物更重要。不属于这条流的 kind
 * 一律标 `ignored` 并留痕，**不转发、不猜**。
 *
 * 为什么自带一个 reading 类型而不是与列表流共用：共用会让货物名在 reader 与流的收端
 * 各认一次（`cargo(type:)` 交出去，收端再 switch 一遍），而那一份重复漂了不会有编译
 * 错误——表现是「某类货物到了却没人接」。专属类型把货物名钉在**一处**：这里 switch 完，
 * 下游拿到的就是 `.waterfall` / `.cancel` 两个支。
 */
import Foundation

struct ApprovalReading {

    /// 这一帧是什么。
    enum Content: Equatable {
        /// 源此刻的代次：每次上游重建后加一；`nil` = 源此刻没有活的代次。
        case ready(generation: Int?)
        /// 一条待答调用，载荷原样（含 `kind`）。卡上要显示的字段由表自己从 `request` 里取。
        case waterfall(JSONValue)
        /// 一条撤回。唯一携带的寻址信息是 `eventId`。
        case cancel(JSONValue)
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
    /// 它讲的是**开流握手完成**（流层据此退避归零、关掉开流超时），不是「待答表可信」。
    /// 后者由 `ApprovalStore` 按自己的语义决定：每条 `ready` 清空，随后等网关重放。
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
            // 按「重试之后结果会不会不同」分，不按错得多严重分：源没就绪、网关内部错都
            // 可能一次就好；「这台网关不认 approvals」重试一万次也一样。
            return failure.isRetryable ? .retry : .stop
        case .ready, .waterfall, .cancel, .ignored:
            return .keep
        }
    }
}

/**
 * 把一帧已解好的入站帧判成 `ApprovalReading` —— 纯函数，不碰 socket、不持状态。
 */
enum ApprovalStreamReader {

    static func read(_ frame: InboundFrame) -> ApprovalReading {
        switch frame.type {
        case "item":
            guard case .item(.connectionItem(let payload))? = frame.payload,
                  let kind = payload["kind"]?.string else {
                return ApprovalReading(content: .ignored)
            }
            switch kind {
            case "ready":
                // `generation` 读不出（缺席、非整数、负数）一律 `nil`：
                // 宁可说不知道，也不补一个看起来正常的数。
                return ApprovalReading(content: .ready(generation: payload["generation"]?.int))
            case "waterfall":
                return ApprovalReading(content: .waterfall(payload))
            case "cancel":
                return ApprovalReading(content: .cancel(payload))
            default:
                // 留痕要带**名字**：别的流的货物漏到这条流上时，现场只剩这一行；
                // 不带名字就分不出「网关推错了流」与「这条流坏了」。
                Log.warn(Log.Module.session,
                         "dropped an item kind the approvals stream does not carry: \(kind)")
                return ApprovalReading(content: .ignored)
            }

        case "error":
            guard case .refused(let failure)? = frame.payload else {
                // 解不出载荷的 error 帧已在解码层兜成 internal-error，正常走不到这里。
                return ApprovalReading(content: .refused(GatewayFailure(
                    code: GatewayErrorCode.internalError.rawValue, message: ""
                )))
            }
            return ApprovalReading(content: .refused(failure))

        case "end":
            return ApprovalReading(content: .ended)

        default:
            return ApprovalReading(content: .ignored)
        }
    }
}
