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
 * 把一帧线上文本判成 `StreamReading` —— 纯函数，不碰 socket、不持状态。
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
                // 形状不认识：丢弃，不重试也不猜。
                return StreamReading(content: .ignored)
            }
            switch payload {
            case .opening(let shape):
                guard let opening = shape.frame() else {
                    // 三字段都在却成形不了（类型不对）。留痕在这一跳：解不出打开帧的那一帧
                    // 正是开流超时的第一现场，而 `.ignored` 不携带原因。
                    Log.warn(Log.Module.session, "opening unparsable (payload shape rejected)")
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
                // 码都读不出：按内部错误兜底，与缺 `code` 时的旧行为一致（那种帧不该静默消失）。
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
