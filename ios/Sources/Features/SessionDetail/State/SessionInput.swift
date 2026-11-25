/**
 * 一屏的输入侧：持久窗口的镜像、还没定稿的草稿、以及扣下来等点名的定稿。
 *
 * 消费者是 `SessionSync`（读窗口事实、发起翻页、吸收帧、喂食引擎）与它的用例。
 * `SessionMirror` 与 `TransientChannel` 都不外露 —— 交出去等于把它们的成员散回给调用方，
 * 而「改它们的接口要跟几处」正是这一层要收的东西。
 *
 * 三件事必须同处一处：镜像、草稿与暂存（「这条定稿是不是比草稿先到」要同时读三者）；
 * 窗口事实与翻页的成对动作（请求权在途而窗口已变的中间态对外不可见）；草稿的消化与它的诊断。
 */
import Foundation

@MainActor
final class SessionInput {

    /// 本屏会话号 —— 投影订阅只收这一条。
    private let sessionId: String
    /// 连接级投影流的收端（App 级一个实例）。`nil` = 这一屏不订阅。
    private let control: ControlStream?
    /// 投影订阅的退订 token。
    private var controlSubscription: (() -> Void)?

    /// 本地权威副本。位置只由几个合并方法推进，改它的方法都要求一份服务端回应。
    private var window = SessionMirror()

    // MARK: - 接线（由装配点在 `init` 末尾接上）

    /// 造一条流。装配点给：编号由流表发，行为对象要指向本屏的读侧。
    /// `nil` = 这一次开流放弃（开流文本编不出来）—— 此时屏幕是空的，状态行说「还没连上」。
    var makeStream: (() -> LogicalStream?)?
    /// 连接阶段。读穿而不是镜像，观察机制会跟到源头。
    var connectionPhase: () -> ConnectionPhase = { .idle }
    /// 每收到本会话的一条投影值就叫一声。
    var onControlValues: ((JSONValue) -> Void)?

    init(sessionId: String, control: ControlStream?) {
        self.sessionId = sessionId
        self.control = control
        // 投影订阅跟着这一屏存在，不跟着流的开关：订在这里，`stop()` 退订。
        // 开流只管事件流 —— 这一屏还没开流时也要能显示当前模型与占用。
        subscribeControl()
    }

    // MARK: - 开关

    /// 本屏那一条流。**惰性**：它的闭包要读 `makeStream`，而在 `init` 里读等于再捕一次 `self`。
    /// 只影响造流的时机，订阅不受影响 —— 订阅在 `init` 里已建。
    private lazy var following = SessionFollowing { [unowned self] in self.makeStream?() }

    /// 连接阶段 —— 读穿注入的那个闭包。
    var phase: ConnectionPhase { connectionPhase() }

    /// 进屏即开流；已开着时是 no-op。
    func start() {
        following.start()
        subscribeControl()
    }

    /// 只重开这一条流 —— 流级动作，不动连接与别的流。
    func retry() { following.retry() }

    /// 离屏：注销这条流并退订投影。连接留在原处（App 级）。
    func stop() {
        following.stop()
        controlSubscription?()
        controlSubscription = nil
    }

    /// 订上投影流：只收本会话那一条。离屏不退会让监听表随每次进出增长，
    /// 而它持有的是弱引用，泄漏不会报错，只会让每次投影都多跑一次空转。
    private func subscribeControl() {
        guard controlSubscription == nil, let control else { return }
        controlSubscription = control.updateListeners.add { [weak self] payload in
            let (sessionId, values, _) = payload
            guard let self, sessionId == self.sessionId else { return }
            self.onControlValues?(values)
        }
    }

    // MARK: - 读数

    /// 窗口之前还有没有更早的记录。
    var hasMore: Bool { window.hasMore }
    /// 当前窗口首条事件的 `seq`。
    var windowStart: Int { window.windowStart }
    /// 打开那一刻日志覆盖到的最后一个 `seq`（含端）。翻页时原样带回，钉住切点。
    var throughSeq: Int { window.throughSeq }
    /// 下一个期望的 `seq` —— 已有内容的末尾（不含）。
    var frontier: Int { window.frontier }
    /// 还没有任何内容 —— 冷启动、或刚被重置。
    var isEmpty: Bool { window.isEmpty }
    /// 窗口全量。只服务日志计数与整段重建这两类需要看全的场景，常态喂食走 `takeFeed`。
    var records: [SessionEvent] { window.events }

    /// 取走这一批新增的持久事件。返回空表示「没有新东西」。
    func takeFeed() -> [SessionEvent] { window.takeFeed() }

    // MARK: - 窗口动作

    /// 打开或重连：新的窗口与本地重对齐，本地更早的部分按起点位置保留或替换。
    func realign(with window: SessionWindow) -> Verdict {
        self.window.realign(with: window)
    }

    /// 往回翻：把更早的一段前插。只接受紧邻的一页。
    func prepend(_ page: SessionWindow) -> Verdict { window.prepend(page) }

    /// 并进一条实时事件。重复丢掉、跳号判缺口。
    func append(_ event: SessionEvent) -> Verdict { window.append(event) }

    /// 把一批记录重新排进下一批。
    ///
    /// 扣下的定稿被作废之后要靠它回来：那一批已经被取走过，没有这一步它们就永久停在窗口里。
    func requeue(_ events: [SessionEvent]) { window.requeue(events) }

    /// 丢弃位置与视图 —— 调用方在收到「位置不作数」之后才调。
    func reset() { window.reset() }

    // MARK: - 翻页

    /// 发起请求的门：同一会话同时只允许一个在途。
    func beginRequest() -> Bool { window.beginRequest() }

    /// 请求失败：放掉在途标记，视图与位置一律不动。
    func abandonRequest() { window.abandonRequest() }

    // MARK: - 草稿与暂存

    /// `end` 帧的点名：这一轮收笔对应哪条持久事件。形状由草稿通道给出，挂在这里是为了
    /// 让编排层不必认识通道类型 —— 那个名字全仓只出现在本文件里。
    typealias Settlement = TransientChannel.Settlement

    private var transient = TransientChannel()

    /// 已到但还没有被点名的定稿 —— 也在里面装「放弃的那一轮的定稿」。
    /// 两者都不喂给引擎：定稿要等 `end` 帧认领，放弃的那一轮本来就不该出现在屏幕上。
    private var held: [Int: SessionEvent] = [:]

    /// 当前的草稿属于哪一轮；`nil` 表示没有进行中的 attempt。
    var liveAttemptId: String? { transient.liveAttemptId }

    var heldCount: Int { held.count }

    func isHeld(_ seq: Int) -> Bool { held[seq] != nil }

    /// 收一条定稿。草稿还开着时先扣着，等 `end` 帧点名（点名认领，不比较文本）。
    ///
    /// 扣不扣看三件事：这条要不要求点名、草稿是不是活着、这一次判定有没有否定本地位置。
    /// 判定本身住 `Verdict`，两侧共用。
    func hold(_ event: SessionEvent, verdict: Verdict) {
        guard Self.needsNaming(event), transient.isLive, !verdict.isReset else { return }
        held[event.seq] = event
    }

    /// 点名：交出那条记录并停止暂存。认领不到时返回 `nil`，调用方不得拿一条「看起来像」的顶上。
    func named(_ seq: Int) -> SessionEvent? { held.removeValue(forKey: seq) }

    /// 整批作废：按 `seq` 升序排回下一批再清空。
    ///
    /// 排序不是洁癖：字典遍历序不定，降序喂进追加路径会撞引擎的「非单调匹配」不变量。
    func drainHeld() {
        guard !held.isEmpty else { return }
        window.requeue(held.values.sorted { $0.seq < $1.seq })
        held.removeAll()
    }

    /// 只清不排回 —— 窗口一起被清空时才用它，那时排回没有可去之处。
    func clearHeld() { held.removeAll() }

    /// 消化一条未定稿帧。`.broken` 的诊断留在这里：那两个读数是通道内部的，
    /// 外露一次就多一个口；调用方只按返回值重开流。
    func apply(frame: JSONValue, cursor: Int) -> TransientChannel.Result {
        let before = transient
        let result = transient.apply(frame: frame, cursor: cursor)
        if case .broken = result {
            Log.warn(Log.Module.session, "草稿通道 broken", [
                "expectedRevision": String(describing: before.expectedRevisionDescription),
                "nextChunk": String(describing: before.nextIndexDescription),
                "type": frame["type"]?.string ?? "?",
                "revision": String(describing: frame["revision"]?.int),
                "index": String(describing: frame["index"]?.int),
            ])
        }
        return result
    }

    /// 用打开帧的基线恢复草稿槽位，返回基线里已累积内容对应的事件。
    func apply(baseline: JSONValue, cursor: Int) -> [AssemblyEvent] {
        transient.apply(baseline: baseline, cursor: cursor)
    }

    /// 放掉草稿 —— 打开帧不带基线时用它，基线是服务端此刻的权威。
    func resetTransient() { transient = TransientChannel() }

    /// 这个事件要不要等 `end` 帧点名：只有「这一轮还没收笔」时的定稿事件才需要。
    /// 替换型（压缩点）不是草稿的定稿，照常直接进。
    private static func needsNaming(_ event: SessionEvent) -> Bool {
        guard event.type == "assistant/message" || event.type == "assistant/attempt" else { return false }
        return event.surfaceOp?["op"]?.string != "replace"
    }
}
