/**
 * 订阅流通道的线上形状 —— 与网关 `mac-gateway/src/wire/mux.ts` 按文件名对着看。
 *
 * 网关那一份写着「手机端有一份对应定义 —— 改字段那边必须同改」。这里的每一件都对应
 * `mux.ts` 里的一个接口：
 * - `MuxServerEnvelope` ↔ 服务端帧外壳（`type` / `streamId` / `payload`）；
 * - `FollowRequest` ↔ `FollowRequest`（开一条订阅流的参数）；
 * - `MuxOpenFrame` ↔ 客户端开流帧（`MuxClientFrame` 里 `type: "open"` 那一支）；
 * - `MuxCancelFrame` ↔ 同一联合里的 `type: "cancel"` 那一支；
 * - `OpeningFrame` ↔ `FollowOpening`（打开帧的载荷）。
 *
 * 只声明客户端真收发的那几条，不是把网关的全套抄过来。
 *
 * 这个目录只放形状与编解码，不放「这条打开装哪些事件」那类判断：那属于连接层。
 */
import Foundation

// MARK: - 流编号

/**
 * 一条逻辑流的编号 —— **开流那一刻现造，此后不复用**。
 *
 * 类型是字符串而不是整数，是为了让它没有可读含义：编号一旦能被解释（「1 是会话流、
 * 2 是审批流」），复用就跟着来 —— 而复用会让旧流的收尾删到新流的登记、旧流的残帧
 * 与新流同号。网关只要求它非空，怎么造归客户端（`FollowClient` 是唯一的造号点）。
 */
typealias StreamId = String

// MARK: - 帧外壳

/// 服务端帧的外壳：`{type, streamId, payload?}`。
///
/// 三个字段都声明，但**谁都不解释它们**：`type` 只被原样转发给订阅方，`streamId` 只作为
/// 「这条流建成与否」的键，`payload` 是内容本身。
///
/// `streamId` 可选：连接级审批帧没有它（那条帧不属于任何一条流）。
struct MuxServerEnvelope: Decodable {
    let type: String
    let streamId: StreamId?
    let payload: JSONValue?
}

// MARK: - 开流请求

/// 开一条订阅流的请求体 —— 网关侧的同名接口。
///
/// 与网关那份**不同形**：网关的 `FollowRequest` 不含 `op`（`op` 的校验在 `followRequestOf`
/// 里单独一句），客户端这一侧在**编码时写出** `op`。类型自身不存 `op`：存了之后谁都能构造一个
/// `op` 不对的 follow 请求，而那条线上路径不存在。
///
/// 网关另有可选参数 `maxMessages`（打开帧携带的条数上界），客户端从不发它 —— 取服务端默认值。
struct FollowRequest: Encodable {
    let sessionId: String

    private enum CodingKeys: String, CodingKey { case op, sessionId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("follow", forKey: .op)
        try container.encode(sessionId, forKey: .sessionId)
    }
}

/// 开流帧：`{type: "open", streamId: "<编号>", payload: <FollowRequest>}`。
///
/// 构造入口只有一个 —— `following(sessionId:streamId:)`。形状自己决定 `op` 与外壳两层，
/// 调用方给两样：跟谁（会话）与这条流叫什么号。
///
/// 编号由连接层造（它是唯一知道「这条连接上哪些号在用」的地方），文本由状态层拼（`op`
/// 是协议词，连接层不认识）—— 两者在 `FollowClient.open(_:)` 的拼装闭包处对接。
///
/// 拼装点只有一处，在会话详情的状态编排里（`SessionSync.startFollowing()`）。
struct MuxOpenFrame: Encodable {

    let streamId: StreamId

    private let request: FollowRequest

    static func following(sessionId: String, streamId: StreamId) -> MuxOpenFrame {
        MuxOpenFrame(streamId: streamId, request: FollowRequest(sessionId: sessionId))
    }

    private enum CodingKeys: String, CodingKey { case type, streamId, payload }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("open", forKey: .type)
        try container.encode(streamId, forKey: .streamId)
        try container.encode(request, forKey: .payload)
    }

    /// 编成要发出去的那段文本。
    func encoded() throws -> String {
        try muxText(of: self)
    }
}

/// 取消帧：`{type: "cancel", streamId: "<本流>"}`。
///
/// 关一条流只发这一帧，**不断开连接**。它是单向的：服务端回什么都不代表这条流的状态，
/// 所以发完即算关（等确认只会多一个会卡住的状态）。
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

/// 把一帧编成线上文本 —— 两种帧共用的那一条纪律。
///
/// `.sortedKeys` 不是风格问题：字典走 `JSONEncoder` 时键序随哈希，同一份输入连编两次会得到
/// 不同字节 —— 排序之后「同一输入两次编码相同」才是一条能常驻的断言。
private func muxText<Frame: Encodable>(of frame: Frame) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(frame), as: UTF8.self)
}

// MARK: - 打开帧的载荷

/**
 * opening 帧的 typed 形状（网关侧的 `FollowOpening`）：帧原文**就地解码一次**，
 * 不经 `JSONValue → Data → typed` 的往返 —— 那条路上每一步都可能悄悄改掉一次取值。
 *
 * 只解字段、不做改名：`cursor`（订阅流的说法，已读到的位置）到 `SessionPage.asOfSeq`
 * （窗口的说法，窗口末尾、不含）的改名由持有目标名字的一侧做 —— `SessionPage.init(opening:)`。
 *
 * 字段语义（与既有 JSONValue 判读逐字对齐）：
 * - `events` 走 `FailableDecodable` —— 坏事件单条跳过，其余照常显示；
 * - `model` / `occupancy` 用「Optional 包 FailableDecodable」区分
 *   「字段不在 = 服务端读不出，不猜」与「字段在 = 落地或丢弃」两件事；
 * - `assistantStream` 保持 `JSONValue` 原样 —— `parseBaseline` 只认声明字段，量小。
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

    /// 从 item 帧原文解码。形状不是 opening（缺 sessionId / cursor / events）返回 nil——
    /// 路由判据与既有 JSONValue 检查一致，误判不允许发生。
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

/// 事件帧的 typed 信封：payload 本体就是 SessionEvent。
///
/// 「整帧 typed 解一次」是既有做法：先解成 `JSONValue` 再编回去重解，那条路上每一步都可能
/// 悄悄改掉一次取值。
struct FrameWithEvent: Decodable {
    let payload: FailableDecodable<SessionEvent>?
}

/// usage 帧的 typed 信封：payload 本体就是 UsageSnapshot。
struct FrameWithUsage: Decodable {
    let payload: FailableDecodable<UsageSnapshot>?
}
