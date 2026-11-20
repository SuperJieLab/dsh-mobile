/**
 * 审批域从 `$events` 上要的三件事 —— **适配器住在业务侧**。
 *
 * 为什么要有这一层：通信域（`Core/Gateway`）的承诺是「不认识业务」，它只提供一张通用的
 * 听众表（`add` / `fire`）。带业务语义的订阅面（`onWaterfall` / `onCancel`）必须落在
 * 各自的 Feature 里 —— 否则「加一种业务货物」就要改通信域，那条承诺随之失守。
 * `ios/judges` 的 `testCoreHasNoBusinessSubscriptions` 守的就是这条线。
 *
 * `clientId` 也顺路从这里取：它是流的状态，而业务侧要的只是「这条流叫什么」。
 */
import Foundation

@MainActor
struct EventsApprovalSink: ApprovalEventSink {

    private let stream: EventsStream

    init(stream: EventsStream) {
        self.stream = stream
    }

    /// 这条流在网关那里的登记键；还没有过 `ready`（或流已经收起）时为 `nil`。
    var clientId: String? { stream.clientId }

    @discardableResult
    func onWaterfall(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        stream.waterfallListeners.add(handler)
    }

    @discardableResult
    func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        stream.cancelListeners.add(handler)
    }

    @discardableResult
    func onReady(_ handler: @escaping () -> Void) -> () -> Void {
        // `ready` 的载荷是 `Void`（听众表要一个泛型参数），所以这里包一层。
        stream.readyListeners.add { _ in handler() }
    }
}
