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

// MARK: - 帧外壳

/// 服务端帧外壳：`{type, streamId, payload?}`。三个字段都声明，但谁都不解释它们。
/// `streamId` **必填** —— 协议里没有不带编号的帧，于是客户端只需一套消费入口。
struct MuxServerEnvelope: Decodable {
    let type: String
    let streamId: StreamId
    let payload: JSONValue?
}

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

    /// 从 item 帧原文解码；形状不是 opening（缺 sessionId / cursor / events）返回 nil。
    static func decode(_ data: Data) -> OpeningFrame? {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let sessionId: String?
                let pageStart: Int?
                let cursor: Int?
                let hasOlder: Bool?
                let events: [FailableDecodable<SessionEvent>]?
                let assistantStream: JSONValue?
                let model: FailableDecodable<ModelSelection>?
                let occupancy: FailableDecodable<UsageSnapshot>?
            }
            let payload: Payload?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = envelope.payload,
              let sessionId = payload.sessionId,
              let cursor = payload.cursor,
              let failableEvents = payload.events else { return nil }
        return OpeningFrame(
            sessionId: sessionId,
            pageStart: payload.pageStart ?? 0,
            cursor: cursor,
            hasOlder: payload.hasOlder ?? false,
            events: failableEvents.compactMap(\.value),
            assistantStream: payload.assistantStream,
            model: payload.model?.value,
            occupancy: payload.occupancy?.value
        )
    }
}

// MARK: - 两类带 typed 载荷的整帧信封

/// 事件帧的 typed 信封：payload 本体就是 SessionEvent（整帧 typed 解一次，不经往返）。
struct FrameWithEvent: Decodable {
    let payload: FailableDecodable<SessionEvent>?
}

/// usage 帧的 typed 信封：payload 本体就是 UsageSnapshot。
struct FrameWithUsage: Decodable {
    let payload: FailableDecodable<UsageSnapshot>?
}
