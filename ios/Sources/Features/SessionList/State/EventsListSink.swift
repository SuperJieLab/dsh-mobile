/**
 * 列表域从 `$events` 上要的两件事 —— 与审批那个适配器同一个理由：**订阅面住在业务侧**。
 *
 * 通信域只给一张听众表；「一条增量」与「一次报到」怎么解释、认不出怎么办，都是列表域的事。
 * `SessionListEventSink` 这个窄协议因此由本适配器满足，而不是由 `EventsStream` 直接实现。
 */
import Foundation

@MainActor
struct EventsListSink: SessionListEventSink {

    private let stream: EventsStream

    init(stream: EventsStream) {
        self.stream = stream
    }

    @discardableResult
    func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void {
        // 听众表的载荷是元组；这里摊平成两个参数，让消费方只写它关心的那两格。
        stream.emitListeners.add { pair in handler(pair.0, pair.1) }
    }

    @discardableResult
    func onReady(_ handler: @escaping () -> Void) -> () -> Void {
        stream.readyListeners.add { _ in handler() }
    }
}
