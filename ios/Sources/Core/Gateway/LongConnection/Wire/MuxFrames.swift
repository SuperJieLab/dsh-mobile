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

    private enum CodingKeys: String, CodingKey { case op, sessionId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("follow", forKey: .op)
        try container.encode(sessionId, forKey: .sessionId)
    }
}

/// 开一条连接级事件流的请求体：`{"op":"events"}`。
/// **没有会话字段**才是要害：带一个 `sessionId` 不会被网关拒，
/// 却会让两端对「绑不绑会话」的理解分岔。
struct EventsRequest: Encodable {

    private enum CodingKeys: String, CodingKey { case op }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("events", forKey: .op)
    }
}

/// 开流帧：`{type: "open", streamId: <编号>, payload: <载荷>}`。
/// 构造入口只有两个工厂（`following` / `events`），op 与外壳由形状自己决定。
/// 载荷声明成私有的两支而不是泛型：op 与载荷一起变，拆成两个自由度就能构造出「op 与载荷
/// 不配」的帧，而那种帧网关认不出。
/// 编号由连接层造、文本由状态层拼 —— 两者在 `StreamMux.makeStream(_:)` 的注入处对接。
struct MuxOpenFrame: Encodable {

    let streamId: StreamId

    private let payload: Payload

    private enum Payload {
        case follow(FollowRequest)
        case events
    }

    static func following(sessionId: String, streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, payload: .follow(FollowRequest(sessionId: sessionId)))
    }

    static func events(streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, payload: .events)
    }

    private enum CodingKeys: String, CodingKey { case type, streamId, payload }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("open", forKey: .type)
        try container.encode(streamId, forKey: .streamId)
        switch payload {
        case let .follow(request):
            try container.encode(request, forKey: .payload)
        case .events:
            try container.encode(EventsRequest(), forKey: .payload)
        }
    }

    /// 编成要发出去的那段文本。
    func encoded() throws -> String {
        try muxText(of: self)
    }
}

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
    let occupancy: UsageSnapshot?

    /// 载荷的线上形状。三个字段（sessionId / cursor / events）同在才成形，其余都可缺。
    struct Payload: Decodable {
        let sessionId: String?
        let pageStart: Int?
        let cursor: Int?
        let hasOlder: Bool?
        let events: [FailableDecodable<SessionEvent>]?
        let assistantStream: JSONValue?
        let model: FailableDecodable<ModelSelection>?
        let occupancy: FailableDecodable<UsageSnapshot>?

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
                occupancy: occupancy?.value
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

    /// 线上字节数。只由 `decode(_:)` 补 —— `recordPerf` 用它，缺了会静默变 0。
    private(set) var byteCount: Int = 0

    private enum CodingKeys: String, CodingKey { case type, streamId, payload }

    /// 给测试与本模块内构造用。线上帧一律走 `decode(_:)` —— 只有它带 `byteCount`。
    init(type: String, streamId: StreamId, payload: InboundPayload? = nil) {
        self.type = type
        self.streamId = streamId
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self.type = type
        streamId = try container.decode(StreamId.self, forKey: .streamId)

        switch type {
        case "item":
            payload = (try? container.decode(ItemPayload.self, forKey: .payload)).map(InboundPayload.item)
        case "error":
            payload = (try? container.decode(GatewayFailure.self, forKey: .payload)).map(InboundPayload.refused)
        case "usage":
            payload = (try? container.decode(UsageFramePayload.self, forKey: .payload)).map(InboundPayload.usage)
        default:
            payload = nil
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
    case usage(UsageFramePayload)
}

/**
 usage 帧的载荷。

 读数本体是 `UsageSnapshot`，但**会话归属**要一起带出来：帧串流时会收到别人的占用，
 判读层拿它跟本流比对才能决定画不画。只留快照不留归属，那条判据就没有落点。
 */
struct UsageFramePayload: Decodable {

    let sessionId: String?
    let snapshot: UsageSnapshot

    private enum CodingKeys: String, CodingKey { case sessionId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        // 快照自己那一层不认 `sessionId`：未声明的 key 由它跳过，这里不重复声明。
        snapshot = try UsageSnapshot(from: decoder)
    }
}

/**
 `item` 帧的四种载荷形状。

 **分派顺序是契约**：同一帧同时满足两条判据时取靠前的那条。改顺序不会编译失败，
 只会让某一类帧悄悄换支，所以有一条判据把它钉住。
 */
enum ItemPayload: Decodable {

    case opening(OpeningFrame.Payload)
    case connectionItem(JSONValue)
    case transient(JSONValue)
    case sessionEvent(SessionEvent)

    private enum CodingKeys: String, CodingKey {
        case sessionId, cursor, events, kind, type, seq, frame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // ① 最具体：三个字段同在才是打开帧。它必须在最前 —— 打开帧的载荷里也有 `type`。
        if container.contains(.sessionId), container.contains(.cursor), container.contains(.events) {
            self = .opening(try OpeningFrame.Payload(from: decoder))
            return
        }
        // ② 事件流的货物：整份载荷原样保留，消费方要的就是任意形状。
        if container.contains(.kind) {
            self = .connectionItem(try JSONValue(from: decoder))
            return
        }
        // ③ 未定稿帧：带 `type` 但没有 `seq`，必须排在事件帧之前。
        //    内层 `frame` 缺席是正常的（上游没带未定稿内容），给 `.null` 而不是判成坏帧。
        if try container.decodeIfPresent(String.self, forKey: .type) == "assistant-stream" {
            self = .transient(try container.decodeIfPresent(JSONValue.self, forKey: .frame) ?? .null)
            return
        }
        // ④ 事件帧：`type` + `seq`。
        if container.contains(.type), container.contains(.seq) {
            self = .sessionEvent(try SessionEvent(from: decoder))
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: container.codingPath,
            debugDescription: "item 载荷不属于本版认识的任何一种形状"
        ))
    }
}
