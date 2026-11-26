/**
 * 一屏的投影：帧到达之后的所有判定，以及「什么时候把它物化上屏」。
 *
 * 消费者是 `SessionBehavior`（经 `apply` / `recordPerf` 两扇门）与 `SessionSync`（装配、转发读数、
 * 收八条接线）。它不持连接、不做翻页、不持分页读数 —— 那三样分别属于连接层与协调者。
 *
 * 三件事必须同处：引擎与变化集（物化要按变化集取键）、帧合并与两个调度标志（一帧只物化一次）、
 * 帧的消化与引擎（哪些事件进引擎、进之前怎么过滤）。用户看得见的句子不在这里。
 */
import Foundation

@MainActor
@Observable
final class SessionProjection {

    /// 日志与服务端对号用的会话标识 —— `recordPerf` 与 `SessionBehavior.label` 都要它。
    let sessionId: String

    /// 窗口与暂存的读写口 —— 帧的消化要经它读写，但不持它的内部类型。
    private let input: SessionInput
    /// 状态行 —— 共享对象，三族动作共写同一条。
    private let statusBox: SessionStatus
    /// 当前显示的模型 —— 与读写两侧共写同一个镜像。
    private let models: SessionModelMirror

    /// 屏幕上要画的东西。`snapshot` 里还留着 hidden 的节点（内容被清空但身份还在），
    /// 视图只取 `visible` —— 那一半才是「不闪」的另一半。
    private(set) var snapshot: ChatSnapshot = .empty

    // MARK: - 接线（由装配点在 `init` 之后接上）

    /// 物化完成：新快照已经在 `snapshot` 里，可以让别的单元跟着动了。
    var onSnapshotPublished: (() -> Void)?
    /// 该刷一屏了 —— 投影不自己刷，因为刷屏还要更新协调者那边的两个计数。
    var onRefreshNeeded: (() -> Void)?
    /// 打开帧里已经有的持久记录（乐观行要据此记账）。
    var onDurableRecords: (([SessionRecord]) -> Void)?
    /// 一条数据帧到达（打开帧 / 事件 / 草稿）—— 读数单元据此记时刻。
    var onDataFrame: (() -> Void)?
    /// 一条落定的用户消息认领了哪条乐观行。只在「认领得到且判定不是重置」时叫。
    var onClaimedRow: ((String) -> Void)?
    /// 一条判定 —— 「对不上」的告知由协调者收。
    var onVerdict: ((Verdict) -> Void)?
    /// 位置被否定：镜像与引擎要重来，乐观行只清「已上屏待退休」那本账（行本身留着）。
    /// 七步的顺序由协调者写。
    var onRebuildNeeded: (() -> Void)?
    /// 打开帧带来的投影值：占用、模型、权限三格的初值。
    var onOpeningProjections: ((ProjectionBlock) -> Void)?
    /// 权限那一格只关心「当前值可能变了」那三类。
    var onLiveEventType: ((String) -> Void)?

    /// 事件 → 节点。引擎跨刷新保留：身份表在里面，重建它就等于把所有节点的身份重来一遍。
    private var conversation = SessionProjection.makeAssembler()
    /// 节点 → 屏幕上那一列（排序在这里，不在引擎里）。
    private var builder = ChatSnapshotBuilder()
    /// 上一次刷新之后攒下的变化。写入路径都往这里并，物化时取走。
    private var pendingChange = AssemblyChange.none
    /// 刷新合并闸：事件帧批处理，判定在值类型 `RefreshGate`。
    private var refreshGate = RefreshGate()
    /// flush 是否已有一次调度在途（防重复调度）。
    private var flushScheduled = false
    /// 草稿的物化是否已有一次调度在途。
    private var snapshotScheduled = false
    /// 合并窗口 = 一个渲染帧量级。未定稿内容逐帧到达无感知；事件文本晚一帧出现。
    private static let flushWindowNanos: UInt64 = 16_000_000

    init(sessionId: String, input: SessionInput, statusBox: SessionStatus, models: SessionModelMirror) {
        self.sessionId = sessionId
        self.input = input
        self.statusBox = statusBox
        self.models = models
    }

    private static func makeAssembler() -> ConversationAssembler {
        ConversationAssembler(
            definitions: [
                AnyNodeDefinition(AssistantStepDefinition()),
                AnyNodeDefinition(MessageDefinition()),
                AnyNodeDefinition(ProcessDefinition()),
                AnyNodeDefinition(CommandDefinition()),
            ],
            // 不变量被破坏时视图会少行或错位，而 `assertionFailure` 在 Release 里没有声音。
            onAnomaly: { code, fields in
                // 正文固定短语、码走字段：这样 grep `code=non-monotonic-match` 就能捞出来，
                // 也不必把中文句子写进 State：用户可见的句子归 Display/。
                Log.warn(Log.Module.session, "conversation invariant broken",
                         fields.merging(["code": code]) { current, _ in current })
            }
        )
    }

    // MARK: - 两扇门（流层只经这两个口回指）

    /// 打开帧与事件帧的埋点；其余类别一个渲染帧就完了，计时只会撑大日志。
    /// 与 `apply` 分开是为了顺序：两者之差正是这一跳的耗时。
    func recordPerf(_ reading: StreamReading, bytes: Int, recv: Double, apply: Double) {
        switch reading.content {
        case .opening(let opening):
            Log.perf(Log.Module.session, PerfRecord(
                seg: .dev, t: PerfRecord.nowMs(), sessionId: opening.header.id, seq: opening.cursor,
                fields: ["kind": .text("opening"), "devRecv": .number(recv),
                         "devApply": .number(apply), "bytes": .number(Double(bytes))]
            ))
        case .event(let event):
            Log.perf(Log.Module.session, PerfRecord(
                seg: .dev, t: PerfRecord.nowMs(), sessionId: sessionId, seq: event.seq,
                fields: ["kind": .text("event"), "devRecv": .number(recv),
                         "devApply": .number(apply), "bytes": .number(Double(bytes))]
            ))
        case .transient, .refused, .ended, .ignored:
            break
        }
    }

    /// 一帧的副作用；判读已在 `SessionStreamReader` 做完，「接下来怎么办」随 `reading.next`
    /// 回给连接层。对外开放只为 `SessionBehavior` 调用 —— 别把 `input` 交出去。
    func apply(_ reading: StreamReading) {
        switch reading.content {
        case .opening(let opening):
            applySnapshot(opening)
            onOpeningProjections?(opening.projections)
        case .event(let event):
            applyLiveEvent(event)
        case .transient(let frame):
            applyTransient(frame)
        case .refused(let failure):
            handleStreamRefusal(failure)
        case .ended, .ignored:
            // 收尾帧与「这一帧不归我管」都没有副作用：重开是连接层照着 `next` 做的事。
            break
        }
    }

    // MARK: - 刷新（协调者的 `refreshView` 与它自己的五处都走这里）

    /// 记一帧到达。control 与打开帧的投影基线两条路不经过 `apply`，但同样是「数据到了」。
    /// 喂一批、再物化一次。计数不在这里 —— 它们是协调者的读口。
    func refresh() {
        feedEngine()
        refreshSnapshot()
    }

    /// 引擎与 builder 与变化集一起重来。三步必须连续：引擎重建了而变化集还留着旧键，
    /// 下一次物化就会去取不存在的键。
    func rebuild() {
        conversation = SessionProjection.makeAssembler()
        builder = ChatSnapshotBuilder()
        pendingChange = .none
    }

    /// 重导次数 —— **为判据而留的读数**，与引擎那一个计同源。
    /// 它量的不是耗时，是「这次刷新碰了几格」：全量就是历史长度，增量就是变化量。
    var buildViewNodeCount: Int { conversation.buildViewNodeCount }

    // MARK: - 帧的消化

    private func applySnapshot(_ snapshot: SnapshotFrame) {
        onDataFrame?()
        // 打开帧里已经有了的那几条：持久事件比乐观行权威。记账即可 ——
        // 紧随其后的刷新会把新快照建好，再撤（撤早了会空一帧）。
        onDurableRecords?(snapshot.records)
        // 手空着时等价于「打开」，重连时走「重对齐」：保留更早的部分。
        let wasEmpty = input.isEmpty
        let verdict = input.realign(with: SessionWindow(opening: snapshot))

        // 一条新流开始：上一代扣着没点名的定稿不再等点名 —— 要么会作为普通事件重来，
        // 要么属于已结束的那一轮。作废只是「不再等认领」，记录本身要排回队列（否则静默少一行）。
        if input.heldCount > 0 {
            Log.warn(Log.Module.session, "新的一条流开始，上一代未认领的定稿作废",
                     ["count": String(input.heldCount)])
            input.drainHeld()
        }
        // 旧草稿先退役：它的 attempt 已经结束或换了人，留着会与新基线拼成两段重复文本。
        if let previous = input.liveAttemptId {
            record(conversation.settleAssistant(attemptId: previous, settlement: nil))
        }

        // 先把持久窗口喂给引擎，再放基线事件 —— 顺序不能反：
        // 基线进的是「空引擎」，而紧接着的刷新会用持久窗口重建整段，把基线抹掉。
        onRefreshNeeded?()

        // 未定稿基线：opening 带进行中的 attempt 就恢复草稿槽位（基线内容变成事件交给引擎），
        // 没有就清场。基线是服务端此刻的权威，本地那份一律丢掉。
        if let baseline = snapshot.assistantStream {
            for event in input.apply(baseline: baseline, cursor: max(0, input.frontier - 1)) {
                record(conversation.append(event))
            }
            refreshSnapshot()
        } else {
            input.resetTransient()
        }

        // 状态行只在首次建立窗口时更新：重连是传输层事件。
        if wasEmpty {
            statusBox.set(.done(added: addedCount(verdict), recovered: false))
        } else if case .resetRequired(let reason) = verdict {
            // 分档判在 `ResetReason.invalidatesLocalContent`，这里只执行。
            if reason.invalidatesLocalContent {
                onRebuildNeeded?()
                // 清空之后必须刷一次：否则屏幕留着上一段窗口的内容，而引擎已经没有它了。
                onRefreshNeeded?()
                // 镜像与引擎都空了，而这条流不会再送旧窗口。重开流，让服务端送一份新 opening。
                //
                // 必须留到帧处理返回之后再做：在这里同步重开，外层随后仍拿**旧帧**的
                // `establishes` 去结算新代次，会把新开流的超时守卫当场关掉。
                Task { @MainActor [weak self] in self?.input.retry() }
            }
            onVerdict?(verdict)
        }
    }

    /// 一条判定带来的净增条数 —— 只有 `merged` 携带这个数，其余（追平 / 重置 / 拒绝 / 失败）
    /// 算 0。
    private func addedCount(_ verdict: Verdict) -> Int {
        if case .merged(let count) = verdict { return count }
        return 0
    }

    private func applyLiveEvent(_ event: SessionEvent) {
        // 落定的用户消息按 `source.rpcId` 认领乐观行 —— 认不认领得看判定，所以这里只把号传出去。
        let claimed = event.type == "user/message" ? event.data["source"]?["rpcId"]?.string : nil
        onDataFrame?()
        // 上游 gap-free 是契约，重复与跳号各有一种处置（见 `SessionMirror.append`）。
        let verdict = input.append(event)
        // 跳号时持久行进不了视图，那一行不能撤 —— 否则屏幕上什么都没有，要等重连才回来。
        if let claimed, !verdict.isReset {
            onClaimedRow?(claimed)
        }
        // 「未接上」之后事件进不来；告知要跟上现状，否则界面静止却看起来正常。
        if case .resetRequired = verdict { onVerdict?(verdict) }
        // 模型选择的两类事件照同一条流进来 —— 状态机自己判水位与顺序。
        models.absorb(event: event)
        // 权限那一格只关心「当前值可能变了」那三类；哪些算，判定在权限域自己手里。
        onLiveEventType?(event.type)
        // 定稿事件先扣着：attempt 还开着时它可能是「比草稿先到」的那一份，
        // 等 `end` 帧点名再放进来（点名认领，不比较文本）。
        input.hold(event, verdict: verdict)
        // 事件帧只标脏，批到点一次重算（opening / HTTP 同步路径不经闸）。
        if refreshGate.eventArrived() == .openWindow { scheduleFlush() }
    }

    /// 批窗口 = 一个渲染帧量级；到点关批、全量重算一次。判定在 `RefreshGate`。
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushWindowNanos)
            guard let self, self.refreshGate.flushDue() else { return }
            self.flushScheduled = false
            self.onRefreshNeeded?()
        }
    }

    private func applyTransient(_ frame: JSONValue) {
        // 未定稿帧也算「数据到了」：长输出期间可能只有它在流。
        onDataFrame?()
        // 小数序号要落在「最后一条持久事件之后」，所以把当前游标交给通道。
        switch input.apply(frame: frame, cursor: max(0, input.frontier - 1)) {
        case .broken:
            // 基线已丢，后续 chunk 是增量 —— 干等只会残缺，重开流取新基线。
            input.retry()

        case .consumed(let events):
            // 每条 draft 的更新都物化一次会把「每帧 O(n)」放大成「每个 chunk O(n)」。
            // 节奏由定义给：`animationFrame` 合到一帧，其余立刻。
            var change = AssemblyChange.none
            for event in events {
                change.absorb(conversation.append(event))
            }
            record(change)
            switch change.publication {
            case .none: break
            case .animationFrame: scheduleSnapshot()
            case .immediate: refreshSnapshot()
            }

        case .ended(let settlement):
            settle(settlement)
        }
    }

    /// 收笔点名：把扣着的那条定稿喂进去，同时撤掉这一轮的草稿行。
    ///
    /// 认领不到（`seq` 为 `nil`，或被放弃）就只撤草稿 —— 不拿一条「看起来像」的事件顶上。
    private func settle(_ settlement: SessionInput.Settlement) {
        let named = settlement.seq.flatMap { input.named($0) }

        if let seq = settlement.seq {
            if let named, named.type == settlement.eventType {
                Log.debug(Log.Module.session, "定稿点名成功",
                          ["attempt": settlement.attemptId, "seq": String(seq)])
            } else if named == nil, !conversation.contains(order: Double(seq)) {
                // 认领不到：草稿撤了，正式内容却没接上 —— 表现是这一轮少了一段。
                Log.warn(Log.Module.session, "定稿点名落空：草稿已撤，正式内容没接上",
                         ["attempt": settlement.attemptId, "seq": String(seq),
                          "held": String(input.heldCount), "type": settlement.eventType ?? ""])
            } else {
                Log.warn(Log.Module.session, "定稿点名的类型对不上",
                         ["attempt": settlement.attemptId, "seq": String(seq),
                          "type": settlement.eventType ?? "", "heldType": named?.type ?? ""])
            }
        } else {
            // 放弃的那一轮不会再来点名：扣着的定稿全部作废，否则它们会被永久跳过（静默少一行）。
            if input.heldCount > 0 {
                Log.warn(Log.Module.session, "被放弃的一轮留下了未认领的定稿，已作废",
                         ["attempt": settlement.attemptId, "count": String(input.heldCount)])
                // 同上一处：作废不等于丢弃，重新排队让它们作为普通事件进去。
                input.drainHeld()
            }
            Log.info(Log.Module.session, "本轮被放弃：草稿已撤", ["attempt": settlement.attemptId])
        }

        record(conversation.settleAssistant(attemptId: settlement.attemptId,
                                            settlement: named.map(AssemblyEvent.init)))
        // 作废那一支刚把暂存排回队列，这里必须喂一次 —— 否则要等下一条事件到达
        // 才会轮到它们，而那一刻可能永远不来。`refresh` 内含喂食与物化。
        onRefreshNeeded?()
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        // 包成「抛出来的错误」：显示层会解释成「订阅流被拒绝：…」。
        statusBox.set(.failed(step: .streaming, cause: .thrown(RpcClientError.refused(failure))))
        onRefreshNeeded?()
    }

    // MARK: - 物化

    /// 草稿更新的同帧合并：一个渲染帧内多次变化只物化一次。
    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushWindowNanos)
            guard let self else { return }
            self.snapshotScheduled = false
            self.refreshSnapshot()
        }
    }

    /// 记下一次写入的变化。发布时机由调用方决定 —— 草稿那一路要合并到同一帧。
    private func record(_ change: AssemblyChange) {
        pendingChange.absorb(change)
    }

    private func refreshSnapshot() {
        // 上一次刷新到这一次之间攒下的变化。**先取再清**：`nodes(forKeys:)` 期间不会再写引擎，
        // 但万一将来有，清空放在取值之后才安全。
        let change = pendingChange
        pendingChange = .none
        if change.rebuilt || change.touched.isEmpty {
            // 说不清变了哪些 ⇒ 全量。这也是本期之前所有路径的唯一行为。
            builder.replace(conversation.nodes())
        } else {
            builder.apply(conversation.nodes(forKeys: change.touched))
        }
        snapshot = builder.snapshot
        // 发布与「撤掉乐观行」必须同一拍，否则中间那段 `nodes` 退回旧快照，消息消失一帧。
        onSnapshotPublished?()
    }

    /// 把镜像窗口里的新事件喂给引擎：往回长就前插，往前走就追加，接不上就整段重建。
    ///
    /// 「接不上」在重置与乱序补齐时出现 —— 那时身份重来才是对的语义，硬接会把两段不同的
    /// 窗口拼成一个。
    private func feedEngine() {
        // 由写入方交出这一批 —— 不再对整份窗口做两次 `filter` 去反推「哪些是新的」。
        let batch = input.takeFeed()
        guard !batch.isEmpty else { return }
        let fresh = batch.filter {
            !input.isHeld($0.seq) && !conversation.contains(order: Double($0.seq))
        }
        guard !fresh.isEmpty else { return }
        guard let bounds = conversation.bounds else {
            // 引擎里只有草稿（冷进入先放了基线、持久事件还没到）：追加进去，不要整段重建 ——
            // 重建会把草稿连同它的格子一起清掉，屏幕上从空重新长。
            guard !conversation.isEmpty else {
                record(conversation.rebuild(durableEvents().map(AssemblyEvent.init)))
                return
            }
            for event in fresh { record(conversation.append(AssemblyEvent(event))) }
            return
        }
        let orders = fresh.map { Double($0.seq) }
        if orders.allSatisfy({ $0 < bounds.min }) {
            record(conversation.prepend(fresh.map(AssemblyEvent.init)))
            Log.debug(Log.Module.session, "引擎前插", ["count": String(fresh.count),
                                                    "from": String(orders.min() ?? 0)])
        } else if orders.allSatisfy({ $0 > bounds.max }) {
            for event in fresh { record(conversation.append(AssemblyEvent(event))) }
            Log.debug(Log.Module.session, "引擎追加", ["count": String(fresh.count),
                                                    "from": String(orders.min() ?? 0)])
        } else {
            // 两段窗口接不上：身份全部重来（界面上是「整列重挂」）。这不是错误，但必须留下痕迹。
            Log.info(Log.Module.session, "窗口接不上，整段重建",
                     ["fresh": String(fresh.count), "events": String(input.records.count),
                      "knownMin": String(bounds.min), "knownMax": String(bounds.max),
                      "freshMin": String(orders.min() ?? 0), "freshMax": String(orders.max() ?? 0)])
            record(conversation.rebuild(durableEvents().map(AssemblyEvent.init)))
        }
    }

    /// 整份窗口里没被暂存挂起的那批。**只在整段重建的两条路径上调用** ——
    /// 那是稀有路径，O(N) 在这里可以接受；常态路径不碰它。
    private func durableEvents() -> [SessionEvent] {
        input.records.filter { !input.isHeld($0.seq) }
    }
}
