import Foundation

/**
 * 一帧的判读结论：「它是什么」与「这条流接下来怎么办」。流表只读它们决定动作。
 * 「建成」随这一帧一起回来，不由上层主动通报 —— 漏调一次那条流就永远开不成。
 */
struct StreamReading {

    /// 这一帧是什么。
    enum Content {
        /// 打开帧：窗口 + 这条流的锚点。
        case opening(OpeningFrame)
        /// 一条持久事件（载荷本体就是事件）。
        case event(SessionEvent)
        /// 一条未定稿帧（`start` / `chunk` / `end`），原样转出。
        case transient(JSONValue)
        /// 一份占用读数。
        case usage(UsageSnapshot)
        /// 流通道里的协议内拒绝。
        case refused(GatewayFailure)
        /// 流被服务端正常收尾。
        case ended
        /// 认不出来、不属于本流、或解不出的那一部分 —— 丢弃，不重试也不猜。
        case ignored
    }

    let content: Content

    /// 这一帧是否意味着「这条流从此刻建成」。只有打开帧成立。
    var establishes: Bool {
        if case .opening = content { return true }
        return false
    }

    /// 这条流接下来该怎么办。默认什么都不做。
    var next: StreamNext {
        switch content {
        case .ended:
            return .reopen
        case .refused(let failure):
            // 会话级终态再开只会得到同一个结果；其余拒绝值得按这条流自己的退避再试一次。
            return SessionStreamReader.isTerminal(code: failure.code) ? .stop : .retry
        case .opening, .event, .transient, .usage, .ignored:
            return .keep
        }
    }
}

/**
 * 把一帧已解好的入站帧判成 `StreamReading` —— 纯函数，不碰 socket、不持状态。
 * 做成静态函数是它唯一能被断言的形式：判读认的是上游的事件形状，错了既不编译失败、也不会有断言红。
 */
enum SessionStreamReader {

    /// - Parameters:
    ///   - frame: 已解好的入站帧。这里不碰字节 —— 原始文本被解析两次的
    ///     第二个落点就在这里。
    ///   - sessionId: 本流的会话。占用帧要核它：帧串流时会画出别人的占用。
    static func read(_ frame: InboundFrame, sessionId: String) -> StreamReading {
        switch frame.type {
        case "item":
            guard case .item(let payload)? = frame.payload else {
                // 载荷在却解不出：那一帧正是开流超时的第一现场，留痕。
                // 四支都不匹配是另一回事 —— 那是本版不认识的新形状，静默丢弃。
                if frame.payloadRejected {
                    Log.warn(Log.Module.session, "opening unparsable (payload shape rejected)")
                }
                return StreamReading(content: .ignored)
            }
            switch payload {
            case .opening(let shape):
                guard let opening = shape.frame() else {
                    // 分派之后才发现必填字段缺了。与「解不出」同归，但已由上面那一行留过痕。
                    return StreamReading(content: .ignored)
                }
                return StreamReading(content: .opening(opening))
            case .sessionEvent(let event):
                return StreamReading(content: .event(event))
            case .transient(let inner):
                return StreamReading(content: .transient(inner))
            case .connectionItem:
                // 连接级货物不属于会话流：串流来的，丢弃。
                return StreamReading(content: .ignored)
            }

        case "error":
            guard case .refused(let failure)? = frame.payload else {
                // 解不出载荷的 error 帧已在解码层兜成 internal-error，正常走不到这里。
                // 留着是为了「type 说 error、载荷却成了别的」这种不该出现的状态不静默。
                return StreamReading(content: .refused(GatewayFailure(
                    code: GatewayErrorCode.internalError.rawValue, message: ""
                )))
            }
            return StreamReading(content: .refused(failure))

        case "end":
            return StreamReading(content: .ended)

        case "usage":
            guard case .usage(let payload)? = frame.payload,
                  payload.sessionId == sessionId else {
                // 这里不留痕：外部读数串流是常态（每条 `usage` 帧只属于一个会话，而广播
                // 让每条连接都收到别人那一份），记日志只会把真正要看的那几行淹掉。
                return StreamReading(content: .ignored)
            }
            return StreamReading(content: .usage(payload.snapshot))

        default:
            return StreamReading(content: .ignored)
        }
    }

    /**
     * 再开这条流有没有意义 —— `true` 表示会话级终态：再开只会得到同一个结果。
     * 未知码按可重试处理（白名单之外的码不该让会话卡死）；这个判断住这里，因为要不要停由订阅方说。
     */
    static func isTerminal(code: String) -> Bool {
        code == GatewayErrorCode.unknownSession.rawValue
            || code == GatewayErrorCode.unreadableSession.rawValue
            || code == GatewayErrorCode.windowTooLarge.rawValue
    }
}
