/**
 * `$events` 上「待答调用 + 宿主通知」的读口 —— **适配器住在业务侧**。
 *
 * 为什么要有这一层：通信域（`Core/Gateway`）的承诺是「不认识业务」，它只提供几张通用
 * 听众表。带业务语义的订阅面（`onApproval` / `onQuestion`）必须落在各自的 Feature 里 ——
 * 否则「加一种业务货物」就要改通信域，那条承诺随之失守。
 * `ios/judges` 的 `testCoreHasNoBusinessSubscriptions` 守的就是这条线。
 *
 * **分派在这里，只有这里**：两类 `waterfall` 混在同一张表上，各域只订阅自己那一类。
 * 判哪一类用 `PendingEventRouter`（值，可单独测）。
 */
import Foundation

@MainActor
final class EventsPendingSink: PendingEventSink {

    private let stream: EventsStream

    init(stream: EventsStream) {
        self.stream = stream
    }

    /// 这条流在网关那里的登记键；还没有过 `ready`（或流已经收起）时为 `nil`。
    var clientId: String? { stream.clientId }

    @discardableResult
    func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        stream.waterfallListeners.add { payload in
            guard PendingEventRouter.kind(of: payload) == .approval else { return }
            handler(payload)
        }
    }

    @discardableResult
    func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        stream.waterfallListeners.add { payload in
            guard PendingEventRouter.kind(of: payload) == .question else { return }
            handler(payload)
        }
    }

    /// 撤回：只带 `eventId`，两类共用 —— 所以两个域各自收、各自删自己表里的那条。
    @discardableResult
    func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        stream.cancelListeners.add(handler)
    }

    @discardableResult
    func onReady(_ handler: @escaping () -> Void) -> () -> Void {
        // `ready` 的载荷是 `Void`（听众表要一个泛型参数），所以这里包一层。
        stream.readyListeners.add { _ in handler() }
    }

    @discardableResult
    func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void {
        // 听众表的载荷是元组；这里摊平成两个参数，让消费方只写它关心的那两格。
        stream.emitListeners.add { pair in handler(pair.0, pair.1) }
    }
}
