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

    // 四张听众表**只给表，不给具名的订阅口**：`onApproval` / `onQuestion` 那一族住在业务侧
    // 的适配器里（`Features/Approval/State/EventsPendingSink.swift`）。理由不是洁癖 ——
    // 通信域的承诺是「不认识业务」，具名口一旦长在这里，加一种货物就要改通信域，
    // 而那条承诺没有任何编译期保证（`ios/judges` 的 `testCoreHasNoBusinessSubscriptions` 守它）。

    /// 源就绪的听众，按注册顺序调用。**每次 ready 都通知** —— 语义是
    /// 「从这一刻起你看到的都是新的」，消费方据此重建自己的基线。
    let readyListeners = ListenerTable<Void>()
    /// 一条待答调用。
    let waterfallListeners = ListenerTable<JSONValue>()
    /// 一条撤回。
    let cancelListeners = ListenerTable<JSONValue>()
    /// 一条上游事件：名字与参数原样。
    let emitListeners = ListenerTable<(String, JSONValue)>()

    /// 这条流在网关那里的登记键，来自最近一次 `ready`。应答审批要把它带回去。
    ///
    /// **换代不变**：换的是上游那条流，不是这一条。清空的时机只有「这条流真的没了」
    /// （`end` 或终态拒绝）—— 那时网关也已经把登记删了，留着它只会换来一次 not-owner。
    private(set) var clientId: String?

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

    /// 判读之后的那一跳 —— 本类唯一的入口。
    func handle(_ frame: InboundFrame) -> StreamReply {
        switch frame.type {
        case "item":
            // 货物在这一层按 `$events` 的形状解 —— 连接层只把原始值交过来。
            guard let value = frame.value else {
                Log.warn(Log.Module.gateway, "events item has no value (payload shape rejected)")
                return StreamReply()
            }
            switch EventsItem.read(value) {
            case .decoded(.ready(let id)):
                clientId = id
                readyListeners.fire(())
                return StreamReply(establishes: true)
            case .decoded(.waterfall(let value)):
                waterfallListeners.fire(value)
            case .decoded(.cancel(let value)):
                cancelListeners.fire(value)
            case .decoded(.emit(let event, let args)):
                emitListeners.fire((event, args))
            case .unparsable:
                Log.warn(Log.Module.gateway, "events item unparsable (payload shape rejected)")
            case .foreign(let type):
                // S6 的「可见」：丢弃但不能静默 —— 痕迹里带上货物自己的 `type`，
                // 否则「网关推了新东西」与「这条流坏了」在日志里长得一样。
                Log.warn(Log.Module.gateway, "dropped an item type this build does not know",
                         ["type": type ?? "?"])
            }
            return StreamReply()

        case "error":
            guard let failure = frame.failure else {
                return StreamReply(next: .stop)
            }
            Log.warn(Log.Module.gateway, "events stream refused",
                     ["error": failure.code, "reason": failure.message])
            if !failure.isRetryable {
                detached = true
                // 终态拒绝：这条流不会再有 `ready` 了，手里的 id 也就无处可用。
                clientId = nil
            }
            return StreamReply(next: failure.isRetryable ? .retry : .stop)

        case "end":
            // 对端收起了这条流，它的登记也就没了；重开之后由新的 `ready` 换一个新 id。
            clientId = nil
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
