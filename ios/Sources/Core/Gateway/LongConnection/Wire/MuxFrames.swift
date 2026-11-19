/**
 * 订阅流通道的线上形状 —— 与网关 `gateway/src/wire/mux.ts` 对着看，改字段那边必须同改。
 *
 * 只声明客户端真收发的那几条，不是把网关全套抄过来。这个目录只放形状与编解码，
 * 「这条打开装哪些事件」那类判断归连接层。
 */
import Foundation

// MARK: - 流编号

/**
 * 一条逻辑流的编号 —— 开流那一刻现造，此后不复用。
 * 类型是字符串是为了让它没有可读含义：编号一旦能被解释，复用就跟着来。
 */
typealias StreamId = String

// MARK: - 开流请求

/// 开一条订阅流的请求体（网关侧同名接口）。
/// 与网关那份不同形：类型自身不存 `op`，编码时写出 —— 存了之后谁都能构造出 `op` 不对的请求。
/// 网关另有可选 `maxMessages`，客户端从不发它（取服务端默认值）。
struct FollowRequest: Encodable {
    let sessionId: String
}

/// 开流帧：`{type:"open", streamId, endpoint, payload:{args}}`。
///
/// 端点名与上游逐字一致，且**与请求形状绑在一起**：`session/follow` 带会话名，另两条
/// 没有入参（`args` 是空对象）。三个工厂而不是一个带参数的 —— 端点名与请求形状是同一件
/// 事的两处写法，参数化之后它们会成为两个会漂的字符串，而漂了不会有编译错误。
struct MuxOpenFrame: Encodable {

    let streamId: StreamId
    private let endpoint: String
    private let request: Request?

    private enum Request {
        case follow(FollowRequest)
    }

    static func following(sessionId: String, streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "session/follow", request: .follow(FollowRequest(sessionId: sessionId)))
    }

    static func events(streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "$events", request: nil)
    }

    static func control(streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "session/control", request: nil)
    }

    private enum CodingKeys: String, CodingKey { case type, streamId, endpoint, payload }
    private enum PayloadKeys: String, CodingKey { case args }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("open", forKey: .type)
        try container.encode(streamId, forKey: .streamId)
        try container.encode(endpoint, forKey: .endpoint)
        var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        switch request {
        case let .follow(follow)?:
            try payload.encode(follow, forKey: .args)
        case nil:
            try payload.encode(EmptyArguments(), forKey: .args)
        }
    }

    func encoded() throws -> String {
        try muxText(of: self)
    }
}

/// 无入参端点的 `args` —— 编码成 `{}`，不是 `null` 也不是缺席。
private struct EmptyArguments: Encodable {}

/// 取消帧：`{type: "cancel", streamId: <本流>}`。关一条流只发这一帧，**不断开连接**。
/// 它是单向的：发完即算关（等确认只会多一个会卡住的状态）。
struct MuxCancelFrame: Encodable {

    let streamId: StreamId

    private enum CodingKeys: String, CodingKey { case type, streamId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("cancel", forKey: .type)
        try container.encode(streamId, forKey: .streamId)
    }

    func encoded() throws -> String {
        try muxText(of: self)
    }
}

/// 把一帧编成线上文本。`.sortedKeys` 不是风格问题：不排序时键序随哈希，同一输入两次编码不同字节。
private func muxText<Frame: Encodable>(of frame: Frame) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(frame), as: UTF8.self)
}

// MARK: - 打开帧的载荷

/**
 * opening 帧的 typed 形状（网关侧的 `FollowOpening`）：帧原文**就地解码一次**，不经
 * `JSONValue → Data → typed` 的往返 —— 那条路上每一步都可能悄悄改掉一次取值。
 * 坏事件单条跳过（`FailableDecodable`），坏模型 / 坏占用整段忽略。
 */
struct OpeningFrame {
    let sessionId: String
    let pageStart: Int
    let cursor: Int
    let hasOlder: Bool
    let events: [SessionEvent]
    let assistantStream: JSONValue?
    let model: ModelSelection?
    /// 打开时读到的投影基线 —— 与 `session/control` 的 `baseline` 同源。
    /// 客户端以 control 为权威，这里的值只在 control 到达之前当初值用。
    let projections: ProjectionBlock?

    /// 载荷的线上形状。三个字段（sessionId / cursor / events）同在才成形，其余都可缺。
    /// `projections` 用 `FailableDecodable` 包着：这一格坏了只丢这一格，不该让整条打开帧
    /// 变成「解不出」—— 那等于为了一个附加读数丢掉整个窗口。
    struct Payload: Decodable {
        let sessionId: String?
        let pageStart: Int?
        let cursor: Int?
        let hasOlder: Bool?
        let events: [FailableDecodable<SessionEvent>]?
        let assistantStream: JSONValue?
        let model: FailableDecodable<ModelSelection>?
        let projections: FailableDecodable<ProjectionBlock>?

        /// 缺一个必填字段就不是打开帧 —— 交给别的分类，不猜默认值。
        func frame() -> OpeningFrame? {
            guard let sessionId, let cursor, let events else { return nil }
            return OpeningFrame(
                sessionId: sessionId,
                pageStart: pageStart ?? 0,
                cursor: cursor,
                hasOlder: hasOlder ?? false,
                events: events.compactMap(\.value),
                assistantStream: assistantStream,
                model: model?.value,
                projections: projections?.value
            )
        }
    }
}

// MARK: - 入站帧：外壳与载荷一次解完

/**
 一条入站帧。外壳与载荷在**同一次**解码里成形。

 分派靠 key 存在性（`Container.contains(_:)`）—— 它不解值。为了判断「这是哪种形状」
 先建一棵通用树，是同一份字节被解析两次的来源：那棵树在会话流上只被用来回答
 「三个 key 在不在」，然后丢掉。

 认不出的载荷落到 `nil`，由判读层归成 `.ignored`；外壳坏（不是 JSON、缺 `streamId`）
 才是整帧丢 —— 两者不是一件事。
 */
struct InboundFrame: Decodable {

    let type: String
    let streamId: StreamId
    let payload: InboundPayload?

    /// 载荷在、但解不出（与「本来就没有载荷」不是一回事）。判读层据此留痕：
    /// 解不出打开帧的那一帧正是开流超时的第一现场，而 `.ignored` 不携带原因。
    let payloadRejected: Bool

    /// 线上字节数。只由 `decode(_:)` 补 —— `recordPerf` 用它，缺了会静默变 0。
    private(set) var byteCount: Int = 0

    private enum CodingKeys: String, CodingKey { case type, streamId, value, error, payload }

    /// 给测试与本模块内构造用。线上帧一律走 `decode(_:)` —— 只有它带 `byteCount`。
    init(type: String, streamId: StreamId, payload: InboundPayload? = nil) {
        self.type = type
        self.streamId = streamId
        self.payload = payload
        self.payloadRejected = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self.type = type
        streamId = try container.decode(StreamId.self, forKey: .streamId)

        switch type {
        case "item":
            do {
                payload = .item(try container.decode(ItemPayload.self, forKey: .value))
                payloadRejected = false
            } catch {
                // 走到这里只有两种可能：`value` 这一格不在（旧形状 `payload` 就是这种），
                // 或者它在但解不出。**两种都要留痕** —— 前者是「对端还在说旧协议」，
                // 后者是「这一帧坏了」，静默丢弃会让它们都变成「什么都没发生」。
                // 与「不认识」的分界不在这里：不认识的 `type` 走 `.unknown`，不抛错。
                payload = nil
                payloadRejected = true
            }
        case "error":
            let decoded = (try? container.decodeIfPresent(FailurePayload.self, forKey: .error)) ?? nil
            payload = .refused(decoded?.failure
                ?? GatewayFailure(code: GatewayErrorCode.internalError.rawValue, message: ""))
            payloadRejected = false
        default:
            payload = nil
            payloadRejected = false
        }
    }

    /// 唯一入口：解一次，并把字节数带上。
    static func decode(_ data: Data) -> InboundFrame? {
        guard var frame = try? JSONDecoder().decode(InboundFrame.self, from: data) else { return nil }
        frame.byteCount = data.count
        return frame
    }
}

/// 外壳决定的载荷大类。
enum InboundPayload {
    case item(ItemPayload)
    case refused(GatewayFailure)
}

/**
 error 帧的载荷：两个字段都按「缺了就补默认值」解。

 旧实现是逐字段取（`payload["code"]?.string ?? …`），对载荷形状零要求。直接解
 `GatewayFailure` 会要求两个字段**同时**可解，于是「缺 `message`」让整包退化成
 `internal-error + ""` —— 一个 `window-too-large` 就这样从「会话级终态」变成「可重试」。
 */
struct FailurePayload: Decodable {

    let failure: GatewayFailure

    private enum CodingKeys: String, CodingKey { case code, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        failure = GatewayFailure(
            code: try container.decodeIfPresent(String.self, forKey: .code)
                ?? GatewayErrorCode.internalError.rawValue,
            message: try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        )
    }
}


/**
 `item` 帧的四种载荷形状。

 **分派顺序是契约**：同一帧同时满足两条判据时取靠前的那条。改顺序不会编译失败，
 只会让某一类帧悄悄换支，所以有一条判据把它钉住。
 */
/// `item` 载荷解不出的两种原因 —— 与「不认识」分开：这两种要留痕，那一种静默丢弃。
enum ItemPayloadError: Error {
    /// 三个字段都在，但载荷解不成打开帧（类型不对）。
    case openingShapeBroken
    /// 载荷里没有 `type`，连是哪类货物都读不出。
    case missingType
}

/// `item` 的货物 —— 按 `value.type` 分派，**只读这一格**。
///
/// 与旧实现的差别就是 S6 的全部：旧的四支靠「有没有 `seq`」「有没有 `kind`」去猜，
/// 同一帧同时满足两条判据时取靠前的，改顺序不编译失败、只会让某类帧悄悄换支。
/// 现在判别字段由网关写在货物上，客户端只查表。
///
/// 不认识的 `type` 落进 `unknown` 而不是抛错：那是新版本的货物，旧客户端该忽略它、
/// 但不该把整条流判成坏的（S6 的「可见」—— 带原样载荷，留痕时能看出是哪一格）。
enum ItemPayload: Decodable {

    case follow(FollowValue)
    case events(EventsValue)
    case control(ControlValue)
    case unknown(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, event, frame, clientId, args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try container.decodeIfPresent(String.self, forKey: .type) else {
            throw ItemPayloadError.missingType
        }
        switch type {
        case "snapshot":
            // 解不出要换成 `ItemPayloadError`：`InboundFrame` 用「是不是这个类型的错」区分
            // 「解不出」（留痕）与「不认识」（静默丢弃），`DecodingError` 会被当成后者。
            do {
                self = .follow(.opening(try OpeningFrame.Payload(from: decoder)))
            } catch {
                throw ItemPayloadError.openingShapeBroken
            }
        case "event":
            self = .follow(.sessionEvent(try container.decode(SessionEvent.self, forKey: .event)))
        case "assistant-stream":
            self = .follow(.transient(try container.decodeIfPresent(JSONValue.self, forKey: .frame) ?? .null))
        case "ready":
            self = .events(.ready(clientId: try container.decode(String.self, forKey: .clientId)))
        case "emit":
            self = .events(.emit(
                event: try container.decode(String.self, forKey: .event),
                args: try container.decodeIfPresent(JSONValue.self, forKey: .args) ?? .null
            ))
        case "waterfall":
            self = .events(.waterfall(try JSONValue(from: decoder)))
        case "cancel":
            self = .events(.cancel(try JSONValue(from: decoder)))
        case "baseline", "projection":
            self = .control(try ControlValue(from: decoder))
        default:
            self = .unknown(try JSONValue(from: decoder))
        }
    }
}

/// `session/follow` 的三种货物。
enum FollowValue {
    /// 打开窗口（含投影基线）。
    case opening(OpeningFrame.Payload)
    /// 一条已落地的事件。
    case sessionEvent(SessionEvent)
    /// 未定稿帧 —— 一个进行中的 assistant 尝试的增量。
    case transient(JSONValue)
}

/// `$events` 的四种货物。
enum EventsValue {
    /// 连接级事件源就绪。`clientId` 是这条流在源那里的登记键。
    case ready(clientId: String)
    /// 上游事件，名字与参数原样 —— 这一层不解释它。
    case emit(event: String, args: JSONValue)
    /// 一条待答调用。
    case waterfall(JSONValue)
    /// 撤回一条待答调用。
    case cancel(JSONValue)
}


/// 一个会话的投影切取：`{asOfSeq, values}`。
///
/// 两条出口共用这一个类型 —— `session/control` 的 `baseline` 与 `follow` 快照的
/// `projections`。同形就一份，两份会漂。
struct ProjectionBlock: Decodable {
    let asOfSeq: Int
    let values: JSONValue
}

/// `session/control` 的货物 —— 与上游 `SessionControlFrame` 同形。
///
/// **一条流装全部会话的投影**：`baseline` 给出每个会话的一次切取，之后的 `projection`
/// 用 `sessionId` 指明是谁变了，`seq` 是引发变化的那个事件。
enum ControlValue: Decodable {

    /// 打开时的一次全量：`{[sessionId]: ProjectionBlock}`。
    case baseline([String: ProjectionBlock])
    /// 一条增量：`changes` 里每项是 `{key, val}` —— 字段名是 `val`。
    case projection(sessionId: String, seq: Int, changes: [Change])

    /// 一个变了格的键与新值。
    struct Change: Decodable {
        let key: String
        let val: JSONValue
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, sessionId, seq, changes, projections
    }

    private enum BaselineKeys: String, CodingKey { case projections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "baseline":
            // `value.projections` 是中间那一层容器，与上游 `SessionControlBaseline` 同形。
            let value = try container.nestedContainer(keyedBy: BaselineKeys.self, forKey: .value)
            self = .baseline(try value.decode([String: ProjectionBlock].self, forKey: .projections))
        case "projection":
            self = .projection(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                seq: try container.decode(Int.self, forKey: .seq),
                changes: try container.decode([Change].self, forKey: .changes)
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "control 货物只有 baseline 与 projection 两种"
            ))
        }
    }
}