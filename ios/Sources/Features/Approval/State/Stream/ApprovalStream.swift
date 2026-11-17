/**
 * 审批那一条连接级流的收端：代次（源换代次了，去重建表）与两类货物（待答调用、撤回）。
 *
 * 它只开一种流（`{op:"approvals"}`），只认两种货物。**这是拆流的全部理由**：原来那一条
 * `events` 流把审批、列表、宿主事件装在一起，而只有审批会「拒绝开流」（网关在
 * `approvals.ready` 为假时回 `source-unavailable`）—— 绑在一起，等于让最脆的那个
 * 决定另外两条的可用性。
 *
 * 与 `SessionSync` 同一分工：这一层只把线上帧变成三类信号（代次 / 一条待答 / 一条撤回），
 * 卡怎么排、什么时候重算由 `ApprovalStore` 答。
 */
import Foundation

@MainActor
final class ApprovalStream {

    /// 最后一次从源收到的代次。网关发不带代次的 `ready` 时置空 —— 那一刻旧基线算旧的。
    /// 它不跟踪「这一头断没断」：socket 断开期间这个值保持原样，单看它会得出「断线期间还新」。
    private(set) var generation: Int?

    /// 代次变化的听众，按注册顺序调用。失效那一次带 `nil`。
    private let generationListeners = ListenerTable<Int?>()
    /// 一条待答调用到达。
    private let waterfallListeners = ListenerTable<JSONValue>()
    /// 一条撤回到达。
    private let cancelListeners = ListenerTable<JSONValue>()

    /// 这条流本身。`close()` / `restart()` 都在它上面 —— 连接级动作一个都不在这里。
    private var stream: LogicalStream?

    /// 这条流被**终态**拒绝收起了（流层 `forget` 了它，业务侧收不到通知）。
    /// 它让 `attach` 可以再入一次：否则 `stream != nil` 会把重挂挡掉，而那条流早就不在表里了。
    private var detached = false

    init() {}

    /// 登记这条流。一次只造一条 —— `attach` 在启动编排里调，重放会再来一次，
    /// 而造流不幂等。
    /// 被终态拒绝之后可以再挂（`detached`）：那是「重来一次」的唯一入口。
    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    /// 源换代次时叫醒：消费方在这里重建表 —— 断线期间的事件永不补发。
    /// 失效也叫一次，带 `nil`。
    @discardableResult
    func onGeneration(_ handler: @escaping (Int?) -> Void) -> () -> Void {
        generationListeners.add(handler)
    }

    /// 一条待答调用到达。
    @discardableResult
    func onWaterfall(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        waterfallListeners.add(handler)
    }

    /// 一条撤回到达。
    @discardableResult
    func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        cancelListeners.add(handler)
    }

    /// 判读之后的那一跳 —— 本类唯一的入口。
    /// 对内可见是为了断言「什么算叫醒消费方」：走真连接也看得见，但那时代次与网络的偶然混在一起。
    func handle(_ reading: ApprovalReading) {
        switch reading.content {
        case let .ready(reported):
            generation = reported
            // 每个 ready 都通知，**不比较新旧**：网关每次开流都发一条，
            // 语义就是「从这一刻起你看到的都是新的」。
            generationListeners.fire(reported)
        case let .waterfall(payload):
            waterfallListeners.fire(payload)
        case let .cancel(payload):
            cancelListeners.fire(payload)
        case let .refused(failure):
            // 不进消费方（拒绝讲的是「接下来怎么办」），但**要留痕**：屏幕上看不见，
            // 版本旧与装配漏了只在这行里分得开。
            Log.warn(Log.Module.gateway, "approvals stream refused",
                     ["error": failure.code, "reason": failure.message])
            // 重试也不会变的那一类会被流层收起，而 `stream` 还非空 —— 标上，回前台时
            // `attach` 才能真的重建。
            if !failure.isRetryable {
                markDetached()
            }
        case .ended, .ignored:
            // 收尾由 `StreamReply` 变成重开；认不出的载荷连名字都没有，分派无处可去。
            break
        }
    }

    /// 作废当前这条流的登记 —— **只标状态，不重复关**。
    private func markDetached() {
        detached = true
    }
}

// MARK: - 这条流的两段自定义

/// 审批流：开流文本只有 `{op:"approvals"}`，帧的判读在 `ApprovalStreamReader`。
/// 流层只问这两件事 —— 它不知道这条流不绑会话，也不认识 `ready` / `waterfall` 这些货物。
extension ApprovalStream: StreamBehavior {

    /// 日志里认人的标识 —— 与另外两条流区分开。
    var label: String { "approvals" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.approvals(streamId: id).encoded()
    }

    func handle(_ frame: InboundFrame) -> StreamReply {
        let reading = ApprovalStreamReader.read(frame)
        handle(reading)
        return StreamReply(establishes: reading.establishes, next: reading.next)
    }
}
