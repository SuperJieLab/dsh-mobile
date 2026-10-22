import Foundation

/**
 * 一帧的判读结论：「它是什么」与「这条流接下来怎么办」。
 *
 * 这两个值都由订阅这条流的一侧给出（见 `SessionStreamReader`），连接层只读它们决定动作 ——
 * 于是连接层不需要认识帧类型的取值。「建成」也不是由谁通报的：它随这一帧一起回来，
 * 由连接层在**收到每一帧时**读一次。让上层主动报「我建成了」的写法漏调一次就没有信号：
 * 心跳永不激活、退避永不归零，表现是每 45 秒静默断一次，而内容照常显示。
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
        /// 一条连接级审批帧。`request` 到这一层时已经核过归属（一定是本会话的）；
        /// `cancel` 与 `sync` 不属于任何会话，原样交给状态层。
        case approval(JSONValue)
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
        case .opening, .event, .transient, .usage, .approval, .ignored:
            return .keep
        }
    }
}

/**
 * 把一帧线上文本判成 `StreamReading` —— 纯函数，不碰 socket、不持状态。
 *
 * 之所以要能不建连接就回答：判读错了不会编译失败，也不会有哪条测试红 —— 它认的是上游的
 * 事件形状，一份会漂移的东西。做成静态函数，是它唯一能被断言的形式。它不持有状态、
 * 不碰 socket；副作用只有日志：解不出打开帧那一行（就绪超时的第一现场），以及被丢掉的
 * 审批那一行（归属不对或压根没有，见 `approval` 分支）。
 *
 * 判据与网关侧的帧语义逐条对齐（两端协定的订阅流一节）：
 *
 * | 输入 | 判成 | 判据 |
 * |---|---|---|
 * | `item`，载荷有 `sessionId` + `cursor` + `events` | 打开帧 | 三个都在才算，缺一不进 |
 * | `item`，载荷 `type` 是 `assistant-stream` | 未定稿帧 | 载荷里的 `frame` 原样转出 |
 * | `item`，载荷有 `type` + `seq` | 事件帧 | 载荷本体就是一条事件；解不出如实丢弃 |
 * | `usage` | 占用读数 | 载荷 `sessionId` 必须等于本流的会话，否则丢弃 |
 * | `approval` | 审批帧 | 没有 `streamId`，与这条流无关；`request` 还要求载荷自带归属且等于本流 |
 * | `error` | 拒绝 | 载荷是 `{code, message}` |
 * | `end` | 收尾 | —— |
 *
 * 顺序不是随意排的：打开帧的判据最严，必须先试；未定稿帧带 `type` 但不带 `seq`，
 * 所以排在事件帧之前。
 */
enum SessionStreamReader {

    /// - Parameters:
    ///   - envelope: 已解出的帧外壳（`type` / `streamId` / `payload`）。
    ///   - raw: 帧的原始字节 —— typed 载荷（打开帧、事件、占用）从它直解一次，
    ///     不经 `JSONValue` 往返。
    ///   - sessionId: 本流的会话。占用帧与审批的 `request` 都要核它：前者串流时会画别人的
    ///     占用，后者会建出一张属于别人的卡。
    static func read(envelope: MuxServerEnvelope, raw: Data, sessionId: String) -> StreamReading {
        switch envelope.type {
        case "item":
            guard let payload = envelope.payload else { return StreamReading(content: .ignored) }
            if payload["sessionId"] != nil && payload["cursor"] != nil && payload["events"] != nil {
                guard let opening = OpeningFrame.decode(raw) else {
                    // 留痕在这一跳：解不出打开帧的那一帧，正是 45 秒就绪超时的第一现场，
                    // 而 `.ignored` 不携带原因 —— 少了这一行，超时日志里就没有线索。
                    Log.warn(Log.Module.session,
                             "opening unparsable (first 120 chars): \(String(decoding: raw.prefix(120), as: UTF8.self))")
                    return StreamReading(content: .ignored)
                }
                return StreamReading(content: .opening(opening))
            }
            if payload["type"]?.string == "assistant-stream" {
                return StreamReading(content: .transient(payload["frame"] ?? .null))
            }
            if payload["type"] != nil && payload["seq"] != nil {
                let envelope = try? JSONDecoder().decode(FrameWithEvent.self, from: raw)
                guard let event = envelope?.payload?.value else {
                    return StreamReading(content: .ignored)
                }
                return StreamReading(content: .event(event))
            }
            return StreamReading(content: .ignored)

        case "error":
            let failure = GatewayFailure(
                code: envelope.payload?["code"]?.string ?? GatewayErrorCode.internalError.rawValue,
                message: envelope.payload?["message"]?.string ?? ""
            )
            return StreamReading(content: .refused(failure))

        case "end":
            return StreamReading(content: .ended)

        case "approval":
            guard let payload = envelope.payload else { return StreamReading(content: .ignored) }
            // 审批帧是**连接级**的（没有编号），广播又面向所有连接 —— 归属只能由载荷自己说。
            // 按 kind 分派而不是「只有 request 才核」：后者会让第四种 kind 绕过归属检查，
            // 而它今天落到状态层是被静默丢掉的，症状要等到有人给它加一个 case 才出现。
            // 分派写成穷举的 switch，新 kind 从「默认放行」变成「默认丢弃」。
            switch payload["kind"]?.string {
            case "request":
                guard let owner = payload["sessionId"]?.string else {
                    // 「新客户端 × 旧网关」的形状：旧网关不发这个字段。宁可少一张卡，
                    // 也不把卡放错会话 —— 这条要看得到，否则现场只有「审批不显示」。
                    Log.warn(Log.Module.session,
                             "dropped an approval with no session (older gateway?) for \"\(sessionId)\"")
                    return StreamReading(content: .ignored)
                }
                guard owner == sessionId else {
                    // 常态而非故障：广播发给了每一条连接，别的会话的那一份注定落在这里。
                    Log.debug(Log.Module.session, "dropped an approval for \"\(owner)\" on \"\(sessionId)\"")
                    return StreamReading(content: .ignored)
                }
                return StreamReading(content: .approval(payload))
            case "cancel", "sync":
                // 两者不带归属，也不该被这条规则误伤：前者按 `eventId` 全局寻址（可能指向
                // 一条早已不在表里的项），后者是整条连接的名单，都与「哪一屏」无关。
                return StreamReading(content: .approval(payload))
            default:
                // 认不出的审批载荷：不猜，也不交给状态层。
                return StreamReading(content: .ignored)
            }

        case "usage":
            guard let payload = envelope.payload,
                  payload["sessionId"]?.string == sessionId else {
                // 与审批不同，这里不留痕：外部读数串流是常态（每次 `usage` 帧都只属于一个
                // 会话，而广播的每一条连接都会收到别人那一份），记日志只会把真正要看的那几行
                // 淹掉。
                return StreamReading(content: .ignored)
            }
            let envelope = try? JSONDecoder().decode(FrameWithUsage.self, from: raw)
            guard let snapshot = envelope?.payload?.value else {
                return StreamReading(content: .ignored)
            }
            return StreamReading(content: .usage(snapshot))

        default:
            return StreamReading(content: .ignored)
        }
    }

    /**
     * 再开这条流有没有意义 —— `true` 表示这是会话级终态：再开只会得到同一个结果。
     *
     * `window-too-large` 属于这一类：那个窗口不会因为再开而变小，反复尝试只会把一次确定的
     * 拒绝变成一串无用的请求。**未知码按可重试处理** —— 白名单之外的码不该让会话卡死。
     *
     * 这条判断住这里而不是连接层：连接层只按答复执行（默认什么都不做，最坏的偏离是「该停的
     * 多试几次」，看得见）；要不要停由订阅方说。
     */
    static func isTerminal(code: String) -> Bool {
        code == GatewayErrorCode.unknownSession.rawValue
            || code == GatewayErrorCode.unreadableSession.rawValue
            || code == GatewayErrorCode.windowTooLarge.rawValue
    }
}
