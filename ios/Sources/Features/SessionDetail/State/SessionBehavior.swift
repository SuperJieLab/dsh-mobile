/**
 * 把流层交来的一帧翻译成对状态源的一次调用 —— 它与流层之间唯一的事。
 *
 * 不让状态源自己 conform：两个协议的消费者不在同一层（视图 vs 流表），挂在一起就会因为
 * 改流层判读协议而牵动一个视图状态类型。它没有自己的状态。
 */
import Foundation

@MainActor
final class SessionBehavior: StreamBehavior {

    /// 弱引用：流表持有本对象，若本对象强持状态源，就成「视图 → 状态源 ← 本对象 ← 流表 ←
    /// 长连接」的环 —— 视图离屏后状态源被流表吊着，它整个镜像与十几个发布值都还在内存里。
    private weak var owner: SessionSync?
    /// 日志与服务端对号用的会话标识。**必须在造流时定下**：状态源一旦释放，
    /// `handler` 里就取不到它了，而这几个入口本来就是为它服务的。
    private let sessionId: String

    init(owner: SessionSync) {
        self.owner = owner
        self.sessionId = owner.sessionId
    }

    /// 日志里认人的标识 —— 会话 id。流层不解释它。
    var label: String { sessionId }

    /// 凭刚造好的编号拼出开流文本：编号由流表造，`op` 与会话由这一层给。
    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.following(sessionId: sessionId, streamId: id).encoded()
    }

    /// 一帧到手：判读 → 副作用 → 回一句话。
    /// 到达与应用的边界卡在这一跳的两侧：`devRecv` 是帧到手，`devApply` 是本层处理完。
    /// 状态源已消失时回一个**什么都不做**的答复：流表在一次换代次里可能还持有本对象一瞬。
    func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply {
        guard let owner else { return StreamReply() }
        let reading = SessionStreamReader.read(
            envelope: envelope, raw: raw, sessionId: sessionId
        )
        let recv = PerfRecord.nowMs()
        owner.apply(reading)
        let apply = PerfRecord.nowMs()
        owner.recordPerf(reading, bytes: raw.count, recv: recv, apply: apply)
        return StreamReply(establishes: reading.establishes, next: reading.next)
    }
}
