/**
 * 连接级流：一条 `$events`，四种货物分发给两家消费方。
 *
 * **为什么是这一条而不是两条**：上游只有一条，分派按 `value.type` 与 `emit` 的 `event` 名做。
 * 原来拆成 `session-list` 与 `approvals` 两条，理由是「只有审批会拒绝开流」；但上游的
 * `$events` 在源未就绪时整条失败，客户端一样要退避重开 —— 拆分换来的只是与上游不同形。
 *
 * 两条消费方仍各自过滤：审批只认 `waterfall` / `cancel`，列表只认 `emit` 与 `ready`。
 * 分发在这一层做，**不过滤** —— 让每个消费方自己判，是因为「谁该看哪种货物」属于
 * 各自域的语义，写在这里就成了第三处要同步的地方。
 */
import Foundation

@MainActor
final class EventsStream {

    /// 源就绪的听众，按注册顺序调用。**每次 ready 都通知** —— 语义是
    /// 「从这一刻起你看到的都是新的」，消费方据此重建自己的基线。
    private let readyListeners = ListenerTable<Void>()
    /// 一条待答调用。
    private let waterfallListeners = ListenerTable<JSONValue>()
    /// 一条撤回。
    private let cancelListeners = ListenerTable<JSONValue>()
    /// 一条上游事件：名字与参数原样。
    private let emitListeners = ListenerTable<(String, JSONValue)>()

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

    @discardableResult
    func onReady(_ handler: @escaping () -> Void) -> () -> Void {
        readyListeners.add { _ in handler() }
    }

    @discardableResult
    func onWaterfall(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        waterfallListeners.add(handler)
    }

    @discardableResult
    func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        cancelListeners.add(handler)
    }

    @discardableResult
    func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void {
        emitListeners.add { pair in handler(pair.0, pair.1) }
    }

    /// 判读之后的那一跳 —— 本类唯一的入口。
    func handle(_ frame: InboundFrame) -> StreamReply {
        switch frame.type {
        case "item":
            guard case .item(let payload)? = frame.payload else {
                if frame.payloadRejected {
                    Log.warn(Log.Module.gateway, "events item unparsable (payload shape rejected)")
                }
                return StreamReply()
            }
            switch payload {
            case .events(.ready):
                readyListeners.fire(())
                return StreamReply(establishes: true)
            case .events(.waterfall(let value)):
                waterfallListeners.fire(value)
            case .events(.cancel(let value)):
                cancelListeners.fire(value)
            case .events(.emit(let event, let args)):
                emitListeners.fire((event, args))
            case .follow, .control:
                // 别的流的货物：串流来的，丢弃。
                break
            case .unknown(let cargo):
                // S6 的「可见」：丢弃但不能静默 —— 痕迹里带上货物自己的 `type`，
                // 否则「网关推了新东西」与「这条流坏了」在日志里长得一样。
                Log.warn(Log.Module.gateway, "dropped an item type this build does not know",
                         ["type": cargo["type"]?.string ?? "?"])
            }
            return StreamReply()

        case "error":
            guard case .refused(let failure)? = frame.payload else {
                return StreamReply(next: .stop)
            }
            Log.warn(Log.Module.gateway, "events stream refused",
                     ["error": failure.code, "reason": failure.message])
            if !failure.isRetryable {
                detached = true
            }
            return StreamReply(next: failure.isRetryable ? .retry : .stop)

        case "end":
            return StreamReply(next: .reopen)

        default:
            return StreamReply()
        }
    }
}

extension EventsStream: StreamBehavior {

    /// 日志里认人的标识 —— 用端点原文（带 `$`）。
    ///
    /// 不带 `$` 的 `"events"` 与端点名长得一样，会让「流层按端点名分支」的判据把它当成
    /// 那一类写法（`testStreamLayerLooksNeitherUpNorOut` 的禁词表）。这一格只进日志，
    /// 不参与任何分派 —— 开流走 `build` 里的工厂，端点名只有 `wire/endpoints.ts` 定义。
    var label: String { "$events" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.events(streamId: id).encoded()
    }
}
