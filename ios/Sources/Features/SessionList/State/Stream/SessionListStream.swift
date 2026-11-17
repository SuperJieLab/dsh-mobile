/**
 * 列表那一条连接级流的收端：代次（源换代次了，去重读一次列表）与一类货物（列表增量）。
 *
 * 它只开一种流（`{op:"session-list"}`），只认一种货物。**这条流的开口帧不带集合**：
 * 恢复走客户端重读（`SessionListState.reload()`），与上游 Web UI 的 `refreshList()` 同一条路。
 *
 * 与审批流分开的理由写在 `ApprovalStream` 里：只有审批那条会「拒绝开流」，绑在一起等于
 * 让最脆的那个决定两条的可用性。
 */
import Foundation

@MainActor
final class SessionListStream {

    /// 最后一次从源收到的代次。网关发不带代次的 `ready` 时置空。
    private(set) var generation: Int?

    /// 代次变化的听众，按注册顺序调用。失效那一次带 `nil`。
    private let generationListeners = ListenerTable<Int?>()
    /// 一条列表增量的听众。
    private let changeListeners = ListenerTable<JSONValue>()

    /// 这条流本身。`close()` / `restart()` 都在它上面 —— 连接级动作一个都不在这里。
    private var stream: LogicalStream?

    /// 这条流被**终态**拒绝收起了。它让 `attach` 可以再入一次。
    private var detached = false

    init() {}

    /// 登记这条流。一次只造一条（造流不幂等）；被终态拒绝之后可以再挂。
    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    /// 源换代次时叫醒：**消费方在这里重读基线** —— 断线期间的事件永不补发。
    /// 失效也叫一次，带 `nil`。
    @discardableResult
    func onGeneration(_ handler: @escaping (Int?) -> Void) -> () -> Void {
        generationListeners.add(handler)
    }

    /// 一条列表增量到达。
    @discardableResult
    func onChange(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        changeListeners.add(handler)
    }

    /// 判读之后的那一跳 —— 本类唯一的入口。
    func handle(_ reading: SessionListReading) {
        switch reading.content {
        case let .ready(reported):
            generation = reported
            // 每个 ready 都通知，**不比较新旧**：网关每次开流都发一条，
            // 语义就是「从这一刻起你看到的都是新的」。
            generationListeners.fire(reported)
        case let .change(payload):
            changeListeners.fire(payload)
        case let .refused(failure):
            Log.warn(Log.Module.gateway, "session-list stream refused",
                     ["error": failure.code, "reason": failure.message])
            if !failure.isRetryable {
                markDetached()
            }
        case .ended, .ignored:
            break
        }
    }

    private func markDetached() {
        detached = true
    }
}

// MARK: - 这条流的两段自定义

extension SessionListStream: StreamBehavior {

    /// 日志里认人的标识 —— 与另外两条流区分开。
    var label: String { "session-list" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.sessionList(streamId: id).encoded()
    }

    func handle(_ frame: InboundFrame) -> StreamReply {
        let reading = SessionListStreamReader.read(frame)
        handle(reading)
        return StreamReply(establishes: reading.establishes, next: reading.next)
    }
}
