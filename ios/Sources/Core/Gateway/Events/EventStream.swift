import Foundation

/**
 * 「这台机器上发生了什么」—— 连接级那条事件流的**收端**。
 * 两件东西：**代次**（源每次重建加一，失效时缺席；消费方要的是「源换代了，去重读一次」
 * 这个信号）与**货物**（按 kind 名分派）。
 */
@MainActor
final class EventStream {

    /// 最后一次从源收到的代次。网关发不带代次的 `ready` 时置空 —— 那一刻一切基线都算旧的。
    /// 它不跟踪「这一头断没断」：socket 断开期间这个值保持原样，单看它会得出「断线期间还新」。
    private(set) var generation: Int?

    /// 代次变化的听众，按注册顺序调用。失效那一次带 `nil`。
    private var generationHandlers: [(Int?) -> Void] = []

    /// 按事件名分派的听众。名字原样来自上游，本类不解释。
    private var handlers: [String: [(JSONValue) -> Void]] = [:]

    /// 按货物名分派的听众。与上面那个口是**两个命名空间**（emit 的名字在载荷里、kind 在
    /// 外壳里）—— 分开注册，将来真有一条叫 `cancel` 的事件也不会串。
    private var cargoHandlers: [String: [(JSONValue) -> Void]] = [:]

    /// 这条流本身。`close()` / `restart()` 都在它上面 —— 连接级动作一个都不在这里。
    private var stream: LogicalStream?

    /// 这条流被**终态**拒绝收起了（流层 `forget` 了它，业务侧收不到通知）。
    /// 它让 `attach` 可以再入一次：否则 `stream != nil` 会把重挂挡掉，而那条流早就不在表里了。
    private var detached = false

    /// 登记这条流。一次只造一条 —— `attach` 在根视图的 `.task` 里调，视图重放会再来一次，
    /// 而造流不幂等。
    /// 被终态拒绝之后可以再挂（`detached`）：那是「重来一次」的唯一入口。
    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    /// 源换代次时叫醒：消费方在这里重读基线 —— 断线期间的事件永不补发。失效也叫一次，带 `nil`。
    func onGeneration(_ handler: @escaping (Int?) -> Void) {
        generationHandlers.append(handler)
    }

    /// 订阅一类事件。同一个名字可以有两个听众。
    func on(_ event: String, _ handler: @escaping (JSONValue) -> Void) {
        handlers[event, default: []].append(handler)
    }

    /// 订阅一种具名货物。同一个 kind 可以有两个听众。
    func onCargo(_ type: String, _ handler: @escaping (JSONValue) -> Void) {
        cargoHandlers[type, default: []].append(handler)
    }

    /// 作废当前这条流的登记 —— **只标状态，不重复关**。
    ///
    /// 终态拒绝时流层已经 `forget` 了它，这里把标记置上，下一次 `attach` 才会真的重建。
    private func markDetached() {
        detached = true
    }

    /// 判读之后的那一跳 —— 本类唯一的入口。
    /// 对内可见是为了断言「什么算叫醒消费方」：走真连接也看得见，但那时代次与网络的偶然混在一起。
    func handle(_ reading: EventReading) {
        switch reading.content {
        case let .ready(reported):
            generation = reported
            // 每个 ready 都通知，**不比较新旧**：网关每次开流都发一条，
            // 语义就是「从这一刻起你看到的都是新的」。
            for handler in generationHandlers { handler(reported) }
        case let .emit(name, args):
            for handler in handlers[name] ?? [] { handler(args) }
        case let .cargo(type, payload):
            for handler in cargoHandlers[type] ?? [] { handler(payload) }
        case let .refused(failure):
            // 不进消费方（拒绝讲的是「接下来怎么办」），但**要留痕**：屏幕上看不见，
            // 版本旧与装配漏了只在这行里分得开。
            Log.warn(Log.Module.gateway, "event stream refused: \(failure.code) \(failure.message)")
            // 重试也不会变的那一类会被流层收起，而 `stream` 还非空 —— 标上，回前台时
            // `attach` 才能真的重建。
            if !EventReading.retryableCodes.contains(failure.code) {
                markDetached()
            }
        case .ended, .ignored:
            // 收尾由 `StreamReply` 变成重开；认不出的载荷连名字都没有，分派无处可去。
            break
        }
    }
}

// MARK: - 这条流的两段自定义

/// 连接级事件流：开流文本只有 `{op:"events"}`，帧的判读在 `EventReader`。
/// 流层只问这两件事 —— 它不知道这条流不绑会话，也不认识 `ready` / `emit` 这些货物。
extension EventStream: StreamBehavior {

    /// 日志里认人的标识 —— 与另一条流区分开。
    var label: String { "connection-events" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.events(streamId: id).encoded()
    }

    func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply {
        let reading = EventReader.read(envelope: envelope)
        handle(reading)
        return StreamReply(establishes: reading.establishes, next: reading.next)
    }
}
