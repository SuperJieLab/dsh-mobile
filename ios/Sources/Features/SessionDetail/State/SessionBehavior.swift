/**
 * 把流层交来的一帧翻译成对状态源的一次调用 —— **这是它与流层之间唯一的事**。
 *
 * 为什么单独一个类型而不是让状态源自己 conform `StreamBehavior`：两个协议的消费者不在同一层。
 * `@Observable` 状态源的消费者是视图，`StreamBehavior` 的消费者是流表（`Core/Gateway`）。
 * 挂在一个类型上，改流层的判读协议就要动一个视图状态类型，而这两件事没有任何共同的变化原因。
 *
 * 它**没有自己的状态**：一帧进来，判读（纯函数 `SessionStreamReader`）→ 副作用（状态源）
 * → 性能记录 → 回一句「这条流接下来怎么办」。所有判定都在别处，这里只按顺序串起来。
 */
import Foundation

@MainActor
final class SessionBehavior: StreamBehavior {

    /// 弱引用：流表持有本对象，若本对象强持状态源，就成「视图 → 状态源 ← 本对象 ← 流表 ← 长连接」
    /// 的环 —— 视图离屏后状态源被流表吊着，它整个镜像与十几个发布值都还在内存里。
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
    ///
    /// 到达与应用的边界卡在这一跳的两侧：`devRecv` 是帧到手，`devApply` 是本层处理完
    ///（镜像合并、状态机吸收、刷新闸标记都在里面）。
    ///
    /// 状态源已消失时回一个**什么都不做**的答复：流表在一次换代次里可能还持有本对象一瞬，
    /// 那时这一帧的归宿是「丢掉」，而不是「把流关掉」。
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
