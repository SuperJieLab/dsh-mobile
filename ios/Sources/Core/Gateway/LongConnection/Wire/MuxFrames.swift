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

/// 开一条订阅流的请求体 —— 上游 `SessionFollowRequest` 逐字（网关侧同名接口）。
///
/// **窗口参数由客户端决定**：网关不再替我们换算。上一版它把 `maxMessages` 乘二、
/// `minTurns` 改成 1，于是同一屏在手机上比 Web UI 长一倍 —— 两份窗口规则里外各一份，
/// 谁也不会红。这里的四个数就是上游浏览器客户端用的那一组。
struct FollowRequest: Encodable {

    /// 会话地址 —— 带 `kind` 判别字段的联合，不是裸 `sessionId`：将来加一种地址
    /// （`subagent`）时，改的是这一处判别，而不是每个调用点的字段名。
    struct Address: Encodable {
        let kind = "session"
        let sessionId: String
    }

    /// 「走到后可停的下限」与「必须停的轮数」—— 与上游同一组数。
    struct TurnWindow: Encodable {
        let minMessages: Int
        let minTurns: Int
    }

    let address: Address
    /// 打开即激活这个会话（宿主的 `promote`）。**不是可选项**：不带它，会话只被被动观察 ——
    /// 手机上看着一切正常，一发消息就是「会话不在」。
    let activate: Bool
    /// 要进程内的未定稿帧（进行中的 assistant 输出）。
    let assistantStream: Bool
    let maxMessages: Int
    let turnWindow: TurnWindow

    /// 上游浏览器客户端打开会话时用的那一组（`HISTORY_PAGE_OPTIONS`）。
    static func opening(sessionId: String) -> FollowRequest {
        FollowRequest(
            address: Address(sessionId: sessionId),
            activate: true,
            assistantStream: true,
            maxMessages: 500,
            turnWindow: TurnWindow(minMessages: 50, minTurns: 2)
        )
    }
}

/// `args` 里的那一层 `request` 容器 —— 宿主的形参就叫 `request`，线上照抄这一层。
/// 少一层就是 `invalid-args`：网关按「宿主的参数名」判容器，不猜。
private struct FollowArguments: Encodable {
    let request: FollowRequest
}

/// 开流帧：`{type:"open", streamId, endpoint, payload:{args}}`。
///
/// 端点名与上游逐字一致，且**与请求形状绑在一起**：`session/follow` 带会话名，另三条
/// 没有入参（`args` 是空对象）。四个工厂而不是一个带参数的 —— 端点名与请求形状是同一件
/// 事的两处写法，参数化之后它们会成为两个会漂的字符串，而漂了不会有编译错误。
struct MuxOpenFrame: Encodable {

    let streamId: StreamId
    private let endpoint: String
    private let request: Request?

    private enum Request {
        case follow(FollowRequest)
    }

    static func following(sessionId: String, streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "session/follow",
                     request: .follow(FollowRequest.opening(sessionId: sessionId)))
    }

    static func events(streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "$events", request: nil)
    }

    static func control(streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "session/control", request: nil)
    }

    /// 组清单流：与 `control` 一样没有入参 —— 组是进程级的，不分会话。
    static func workspace(streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, endpoint: "workspace/follow", request: nil)
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
            try payload.encode(FollowArguments(request: follow), forKey: .args)
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

/// 把一帧编成线上文本。
///
/// `.sortedKeys` 不是风格问题：不排序时键序随哈希，同一输入两次编码不同字节。
/// `.withoutEscapingSlashes` 也不是：默认编码器会把 `session/follow` 写成 `session\/follow`，
/// 而共守样本（两端各有一条判据读它）钉的是**不转义**的字节。两种写法 JSON 解析等价，
/// 但字节不一致会让「两端编的是不是同一帧」这条判据失去意义。
private func muxText<Frame: Encodable>(of frame: Frame) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(frame), as: UTF8.self)
}

// MARK: - 打开帧的载荷

/**
 打开帧的 typed 形状 —— 上游 `SessionFollowFrame` 的 `snapshot` 支（网关侧的
 `FollowSnapshot`）：帧原文**就地解码一次**，不经 `JSONValue → Data → typed` 的往返 ——
 那条路上每一步都可能悄悄改掉一次取值。

 **五格必填**：`header` / `cursor` / `records` / `hasMore` / `projections`。缺任何一格
 就不是打开帧 —— 丢弃并留痕，**不补默认值**。补一个默认值等于替服务端声明一件它没说的事：
 `hasMore` 补成 `false` 就是「上面没有了」（往回翻的入口永远不出现），`projections` 补成空
 就是「没有占用」，两种都不会报错。坏记录单条跳过（`FailableDecodable`，那一格解不出的是
 一条事件，不是整帧）。
 */
struct SnapshotFrame {
    /// 会话元信息（九格）。`id` 是会话 id —— 从前那一格叫 `sessionId`。
    let header: SessionWireHeader
    /// 打开覆盖到的最后一个 seq，**含端**。「下一个期望的 seq」是 `cursor + 1`，在入口换算一次。
    let cursor: Int
    let records: [SessionRecord]
    /// 窗口之前是否还有更旧的记录。
    let hasMore: Bool
    /// 打开时读到的投影基线 —— 与 `session/control` 的 `baseline` 同源。
    /// 客户端以 control 为权威，这里的值只在 control 到达之前当初值用。
    let projections: ProjectionBlock
    /// 未定稿基线：一个进行中的 assistant 尝试。不透明 —— 语义归 `TransientChannel`。
    let assistantStream: JSONValue?

    struct Payload: Decodable {
        let header: FailableDecodable<SessionWireHeader>?
        let cursor: Int?
        let records: [FailableDecodable<SessionRecord>]?
        let hasMore: Bool?
        let projections: FailableDecodable<ProjectionBlock>?
        let assistantStream: JSONValue?

        /// 缺一个必填字段就不是打开帧 —— 交给别的分类，不猜默认值。
        func frame() -> SnapshotFrame? {
            guard let header = header?.value,
                  let cursor,
                  let records,
                  let hasMore,
                  let projections = projections?.value
            else { return nil }
            return SnapshotFrame(
                header: header,
                cursor: cursor,
                records: records.compactMap(\.value),
                hasMore: hasMore,
                projections: projections,
                assistantStream: assistantStream
            )
        }
    }
}

// MARK: - 入站帧：外壳解一次，货物留原文

/**
 一条入站帧。**外壳在这里成形，货物只留原文。**

 为什么不再在这一层认货物：`item` 的 `value.type` 在两条流上可以是同一个名字而形状不同
 （`baseline` 在 `session/control` 上是投影表、在 `workspace/follow` 上是组清单）。
 一张全局分派表只能容下其中一种，另一种会在解码层被当成坏帧丢掉 —— 收端连一行代码都
 跑不到。所以这里只回答「谁收这一帧」，是哪种货物由收端按自己那条流解（`FollowItem` /
 `EventsItem` / `ControlValue.read`）。

 认不出的外壳（不是 JSON、缺 `streamId`）整帧丢；`item` 缺 `value` 则留给收端留痕 ——
 两者不是一件事：前者这条连接坏了，后者是「对端还在说旧协议」或「这一帧坏了」。
 */
struct InboundFrame: Decodable {

    let type: String
    let streamId: StreamId

    /// `item` 帧的货物原文（`value` 那一格，已解析成通用树，尚未择型）。
    /// `nil` = 这一格不在（旧形状的 `payload` 就是这种）。
    let value: JSONValue?

    /// `error` 帧的失败。error 是外壳级的、与哪条流无关，所以在这一层解。
    let failure: GatewayFailure?

    /// 线上字节数。只由 `decode(_:)` 补 —— `recordPerf` 用它，缺了会静默变 0。
    private(set) var byteCount: Int = 0

    private enum CodingKeys: String, CodingKey { case type, streamId, value, error }

    /// 给测试与本模块内构造用。线上帧一律走 `decode(_:)` —— 只有它带 `byteCount`。
    init(type: String,
         streamId: StreamId,
         value: JSONValue? = nil,
         failure: GatewayFailure? = nil) {
        self.type = type
        self.streamId = streamId
        self.value = value
        self.failure = failure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self.type = type
        streamId = try container.decode(StreamId.self, forKey: .streamId)

        switch type {
        case "item":
            // 只解到通用树为止：哪种货物由收端定。`value` 缺席时留 `nil`，不在这里补默认值。
            //
            // 刻意不用 `decodeIfPresent`：它把 `null` 也折成 `nil`，于是「这一格不在」与
            // 「它是 null」就分不开了 —— 前者是对端还在说旧协议（`payload`），后者是一次坏帧。
            value = container.contains(.value)
                ? (try? container.decode(JSONValue.self, forKey: .value))
                : nil
            failure = nil
        case "error":
            value = nil
            let decoded = (try? container.decodeIfPresent(FailurePayload.self, forKey: .error)) ?? nil
            failure = decoded?.failure ?? GatewayFailure(code: GatewayErrorCode.internalError.rawValue, message: "")
        default:
            value = nil
            failure = nil
        }
    }

    /// 唯一入口：解一次，并把字节数带上。
    static func decode(_ data: Data) -> InboundFrame? {
        guard var frame = try? JSONDecoder().decode(InboundFrame.self, from: data) else { return nil }
        frame.byteCount = data.count
        return frame
    }
}

/**
 error 帧的载荷：两个字段都按「缺了就补默认值」解。

 旧实现是逐字段取（`payload["code"]?.string ?? …`），对载荷形状零要求。直接解
 `GatewayFailure` 会要求两个字段**同时**可解，于是「缺 `message`」让整包退化成
 `internal-error + ""` —— 一个 `window-too-large` 就这样从「会话级终态」变成「可重试」。
 */
struct FailurePayload: Decodable {

    let failure: GatewayFailure

    private enum CodingKeys: String, CodingKey { case code, message, details }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 三格都按「缺了就补默认值」解，与一元那边的 `GatewayFailure` 同一套规则：
        // 缺 `code` 折成 `internal-error`、缺 `message` 给空串、缺 `details` 给空字典。
        // **两条通道对同一格不能一个严一个宽** —— 那会让同一个失败在两个入口下
        // 一个可读、一个报「报文畸形」。
        failure = GatewayFailure(
            code: try container.decodeIfPresent(String.self, forKey: .code)
                ?? GatewayErrorCode.internalError.rawValue,
            message: try container.decodeIfPresent(String.self, forKey: .message) ?? "",
            details: (try? container.decodeIfPresent([String: JSONValue].self, forKey: .details)) ?? [:]
        )
    }
}

// MARK: - 按流解货物

/**
 一帧货物在**这条流**上的归属。三支而不是「解出来 / 解不出」，因为两件不同的事要分开：

 - `.decoded`：是本流的货物且解得出；
 - `.unparsable`：是本流的 `type`，但字段解不出 —— 这是协议漂移的第一现场，要留痕；
 - `.foreign`：不是本流的货物（含没有 `type`）—— 串流或新版本，丢掉就好。
 */
enum CargoReading<Cargo> {
    case decoded(Cargo)
    case unparsable
    case foreign(String?)
}

/**
 `session/follow` 的三种货物 —— **只有这条流认这三样**。

 判别只看 `value.type` 一格（与从前同一条纪律）；不认得的落 `.foreign`，不猜。
 */
enum FollowItem {

    /// 打开窗口（含投影基线）。
    case opening(SnapshotFrame.Payload)
    /// 一条已落地的事件。
    case sessionEvent(SessionEvent)
    /// 未定稿帧 —— 一个进行中的 assistant 尝试的增量。
    case transient(JSONValue)

    static func read(_ value: JSONValue) -> CargoReading<FollowItem> {
        switch value["type"]?.string {
        case "snapshot":
            let payload = try? SnapshotFrame.Payload(from: JSONValueDecoder(value))
            return payload.map { .decoded(.opening($0)) } ?? .unparsable
        case "event":
            let event = try? SessionEvent(from: JSONValueDecoder(value["event"] ?? .null))
            return event.map { .decoded(.sessionEvent($0)) } ?? .unparsable
        case "assistant-stream":
            // 缺内层 `frame` 是常态（上游没带未定稿内容）：`.null`，不是坏帧。
            return .decoded(.transient(value["frame"] ?? .null))
        default:
            return .foreign(value["type"]?.string)
        }
    }
}

/// `$events` 的四种货物 —— **只有这条流认这四样**。
enum EventsItem {

    /// 连接级事件源就绪。`clientId` 是这条流在源那里的登记键。
    case ready(clientId: String)
    /// 上游事件，名字与参数原样 —— 这一层不解释它。
    case emit(event: String, args: JSONValue)
    /// 一条待答调用。
    case waterfall(JSONValue)
    /// 撤回一条待答调用。
    case cancel(JSONValue)

    static func read(_ value: JSONValue) -> CargoReading<EventsItem> {
        switch value["type"]?.string {
        case "ready":
            guard let clientId = value["clientId"]?.string else { return .unparsable }
            return .decoded(.ready(clientId: clientId))
        case "emit":
            guard let event = value["event"]?.string else { return .unparsable }
            return .decoded(.emit(event: event, args: value["args"] ?? .null))
        case "waterfall":
            return .decoded(.waterfall(value))
        case "cancel":
            return .decoded(.cancel(value))
        default:
            return .foreign(value["type"]?.string)
        }
    }
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
///
/// **只有这条流认 `baseline` 的这一种形状**：`workspace/follow` 也叫 `baseline`，但它是
/// 组清单（另一片里由 `WorkspaceItem` 解）。按流解码的起因就是这一格。
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

extension ControlValue {

    static func read(_ value: JSONValue) -> CargoReading<ControlValue> {
        switch value["type"]?.string {
        case "baseline", "projection":
            let decoded = try? ControlValue(from: JSONValueDecoder(value))
            return decoded.map { .decoded($0) } ?? .unparsable
        default:
            return .foreign(value["type"]?.string)
        }
    }
}
