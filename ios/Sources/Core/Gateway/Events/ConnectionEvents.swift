import Foundation

/**
 * 事件流要的那一件事：登记一条流。
 *
 * 与 `SessionStreamHandle` 同一条理由，受众不同（那里是屏幕，这里是 App 级的事件容器）——
 * 容器只需要 `open`。收一个带 `reconnectNow()` / `deactivate()` 的具体连接宿主，代价是这一跳
 * 不可断言：那个类型要一个真的 `GatewayClient`（真 `URLSession` 路径），于是「判读结论怎么
 * 变成连接层的答复」就只能靠评审看出来。
 */
@MainActor
protocol ConnectionStreamOpening {
    func open(_ subscription: FollowClient.Subscription)
}

/**
 * 「这台机器上发生了什么」—— App 级那条事件流的收端。
 *
 * 两件东西，一件都不能少：
 * - **代次**：源每次重建加一，失效时缺席。它是「我手里这份基线还新不新」的唯一依据，
 *   所以消费方要的不是「第几条事件」，而是「源换代了，去重读一次」这个信号。
 * - **按名字注册**：事件名是上游的词汇（`api-session/added` 等），本类不认识其中任何一个
 *   —— 加一类事件只多一次 `on`，不碰这里的任何一行。
 *
 * 它不持有连接：「登记这条流」是唯一一次调用（`attach`），此后帧从连接层进来。这条流
 * 的失败与重开由连接层按 `StreamReply` 处置，本类只回答「这一帧说了什么」。
 *
 * 它不是 `ObservableObject`：今天没有任何界面读它。将来要读的那一屏可以自己订阅，
 * 观察是那个消费方的需求，不该提前让容器带上发布机制。
 */
@MainActor
final class ConnectionEvents {

    /// 最后一次从源收到的代次。网关发一条**不带代次**的 `ready` 时置空 —— 那一刻源没有活的
    /// 代次，手里一切基线都算旧的。
    ///
    /// 它不跟踪「手机自己这一头断没断」：socket 断开、重连中、事件流被拒之后收起来，这个值都
    /// 保持原样。要判「我这份基线还新不新」的消费方得把两件事合起来看（连接在不在 + 代次在不在），
    /// 单看这一个值会得出「断线期间还新」。
    private(set) var generation: Int?

    /// 代次变化时的听众，按注册顺序调用。
    private var generationHandlers: [(Int) -> Void] = []

    /// 按事件名分派的听众。名字原样来自上游，本类不解释。
    private var handlers: [String: [(JSONValue) -> Void]] = [:]

    /// 登记这条流 —— 与当前会话流平级，先登记后登记都一样。
    ///
    /// `takesUnscoped` 不声明：没有编号的帧（连接级审批）属于会话流，这条流拿到它只会
    /// 多一次「认不出的载荷」。
    func attach(to opener: any ConnectionStreamOpening) {
        opener.open(FollowClient.Subscription(
            owner: self,
            label: "connection-events",
            build: { id in try MuxOpenFrame.events(streamId: id).encoded() },
            handler: { [weak self] envelope, _ in
                guard let self else { return StreamReply() }
                let reading = ConnectionEventReader.read(envelope: envelope)
                self.handle(reading)
                return StreamReply(establishes: reading.establishes, next: reading.next)
            }
        ))
    }

    /// 源换代次时叫醒。消费方在这里重读基线 —— 断线期间的事件永不补发，重读是唯一手段。
    func onGeneration(_ handler: @escaping (Int) -> Void) {
        generationHandlers.append(handler)
    }

    /// 订阅一类事件。同一个名字可以有两个听众。
    func on(_ event: String, _ handler: @escaping (JSONValue) -> Void) {
        handlers[event, default: []].append(handler)
    }

    /// 判读之后的那一跳 —— 本类唯一的入口。
    ///
    /// 对内可见（不 `private`）与 `FollowClient.handleMessage` 同理：这里有一条只有在
    /// 此处才断言得到的契约 —— **什么算叫醒消费方**。走一条真连接也看得见它，但那时
    /// 「源的代次」与网络的偶然混在一起。
    func handle(_ reading: ConnectionEventReading) {
        switch reading.content {
        case let .ready(reported):
            generation = reported
            // 不带代次 = 源失效：只置空，不通知 —— 没有可重读的基线。
            guard let reported else { return }
            // 每个带代次的 ready 都通知，不比较新旧：网关只在源换代次时发它，同一个值
            // 不会出现两次。比较能省一次基线重读，却换来一条没有判据的判定。
            for handler in generationHandlers { handler(reported) }
        case let .emit(name, args):
            for handler in handlers[name] ?? [] { handler(args) }
        case let .refused(failure):
            // 不进消费方（拒绝讲的是「这条流接下来怎么办」，由 `StreamReply` 说），但**要留痕**：
            // 这条流不会重开，屏幕上也不会出现任何东西 —— 「网关版本旧」与「网关装配漏了源」
            // 只在这一行里分得开。
            Log.warn(Log.Module.gateway, "event stream refused: \(failure.code) \(failure.message)")
        case .ended, .ignored:
            // 收尾由 `StreamReply` 变成重开；认不出的载荷连名字都没有，分派无处可去。
            break
        }
    }
}
