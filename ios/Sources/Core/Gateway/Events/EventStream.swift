import Foundation

/**
 * 「这台机器上发生了什么」—— 连接级那条事件流的**收端**（这个名字说的就是这一点：
 * 它是这条流在客户端的代表，不是「一堆事件」）。
 *
 * 两件东西，一件都不能少：
 * - **代次**：源每次重建加一，失效时缺席。它是「我手里这份基线还新不新」的唯一依据，
 *   所以消费方要的不是「第几条事件」，而是「源换代了，去重读一次」这个信号。
 * - **按名字注册**：两个命名空间各一个口 —— 上游事件名（`on`）与流通道的货物名
 *   （`onCargo`，`session-list` / `waterfall` / `cancel`）。名字原样来自协议，本类不解释
 *   其中任何一个 —— 加一类事件或货物只多一次注册，不碰这里的任何一行。
 *
 * 它不持有连接：「登记这条流」是唯一一次调用（`attach`），此后帧从连接层进来。这条流
 * 的失败与重开由连接层按 `StreamReply` 处置，本类只回答「这一帧说了什么」。
 *
 * 它不是 `ObservableObject`：今天没有任何界面读它。将来要读的那一屏可以自己订阅，
 * 观察是那个消费方的需求，不该提前让容器带上发布机制。
 */
@MainActor
final class EventStream {

    /// 最后一次从源收到的代次。网关发一条**不带代次**的 `ready` 时置空 —— 那一刻源没有活的
    /// 代次，手里一切基线都算旧的。
    ///
    /// 它不跟踪「手机自己这一头断没断」：socket 断开、重连中、事件流被拒之后收起来，这个值都
    /// 保持原样。要判「我这份基线还新不新」的消费方得把两件事合起来看（连接在不在 + 代次在不在），
    /// 单看这一个值会得出「断线期间还新」。
    private(set) var generation: Int?

    /// 代次变化的听众，按注册顺序调用。失效那一次带 `nil`。
    private var generationHandlers: [(Int?) -> Void] = []

    /// 按事件名分派的听众。名字原样来自上游，本类不解释。
    private var handlers: [String: [(JSONValue) -> Void]] = [:]

    /// 按货物名分派的听众。名字是流通道的 kind 词汇（`session-list` / `waterfall` / `cancel`），
    /// 与上面那个口是**两个命名空间**（emit 的名字在载荷里、kind 是外壳字段）—— 分开注册，
    /// 将来上游真有一条叫 `cancel` 的事件也不会串。载荷原样交出，解释住消费方。
    private var cargoHandlers: [String: [(JSONValue) -> Void]] = [:]

    /// 这条流本身。`close()` / `restart()` 都在它上面 —— 连接级动作一个都不在这里。
    private var stream: LogicalStream?

    /// 这条流被**终态**拒绝收起了（流层 `forget` 了它，业务侧收不到通知）。
    ///
    /// 它让 `attach` 可以再入一次：没有这个标记，`stream != nil` 会把重挂挡掉，而那条流
    /// 早就不在表里了 —— 一次终态拒绝之后，审批再也到不了。
    private var detached = false

    /// 登记这条流 —— 与当前会话流平级，先登记后登记都一样。
    ///
    /// 一次只造一条：`attach` 在根视图的 `.task` 里调，视图重放时会再来一次，
    /// 而造流不幂等 —— 闸在这里，不在调用方。**被终态拒绝之后可以再挂**（`detached`）：
    /// 那是「重来一次」的唯一入口，回前台时根部会调它。
    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    /// 源换代次时叫醒。消费方在这里重读基线 —— 断线期间的事件永不补发，重读是唯一手段。
    ///
    /// 失效（源没了）也叫一次，带 `nil`：那时能做的只有清空 —— 手里的项一条都答不了。
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
    ///
    /// 对内可见（不 `private`）与 `WebSocketConnection.handleMessage` 同理：这里有一条只有在
    /// 此处才断言得到的契约 —— **什么算叫醒消费方**。走一条真连接也看得见它，但那时
    /// 「源的代次」与网络的偶然混在一起。
    func handle(_ reading: EventReading) {
        switch reading.content {
        case let .ready(reported):
            generation = reported
            // 每个 ready 都通知，**不比较新旧**：网关每次开流都发一条（重连后即使代次
            // 相同也发），而「每一次 ready」的语义是「从这一刻起你看到的都是新的」。
            // 按「值变了才处理」去优化，会让重连之后的重新对齐失效。
            for handler in generationHandlers { handler(reported) }
        case let .emit(name, args):
            for handler in handlers[name] ?? [] { handler(args) }
        case let .cargo(type, payload):
            for handler in cargoHandlers[type] ?? [] { handler(payload) }
        case let .refused(failure):
            // 不进消费方（拒绝讲的是「这条流接下来怎么办」，由 `StreamReply` 说），但**要留痕**：
            // 屏幕上不会出现任何东西 —— 「网关版本旧」与「网关装配漏了源」只在这一行里分得开。
            Log.warn(Log.Module.gateway, "event stream refused: \(failure.code) \(failure.message)")
            // 重试也不会变的那一类：流层会把它收起（`.stop`），而业务侧的 `stream` 字段还非空。
            // 标上，回前台时 `attach` 才能真的重建一条。
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
