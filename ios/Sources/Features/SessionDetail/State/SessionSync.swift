import Foundation

/// 一个会话的**读侧**编排：把「取窗口 / 追新增 / 往回翻」接到状态机上。状态机只管判定，
/// 这里管调用顺序与失败收场：单飞、拉完为止、先窗口后增量。
///
/// 本类只做读：镜像、事件装配、占用、告知、流式未定稿。三样相邻的东西各住一处 ——
/// 状态行（`SessionStatus`）、当前模型（`SessionModelMirror`）、用户动作（`SessionActions`）、
/// 流的开关（`SessionFollowing`）。它们由本类装配并向视图转发，所以视图仍然只认识本对象。
///
/// 拆开的理由是变化触发源不同：读侧随「窗口与快照的协议」变，写侧随「产品动作的语义」变，
/// 流开关随「流的生命周期」变。合成一个类时，改任一处都要重读另外两处的上下文。
/// 用户看得见的句子住 `Display/SyncText.swift`。
@MainActor
@Observable
final class SessionSync {

    /// 屏幕上要画的东西 —— 消息**与过程**；由组装器从同一批事件算出。
    private(set) var nodes: [TranscriptNode] = []

    /// 消息条数 —— 从已组装的节点数，不另存一份（两个出处必然不同步）。
    var messageCount: Int {
        nodes.reduce(0) { count, node in
            if case .message = node { return count + 1 }
            return count
        }
    }
    /// 视图里的事件条数（消息只是其中一部分）。
    private(set) var eventCount = 0
    /// 还能往回翻吗。为真时界面给出入口。
    private(set) var hasOlder = false
    /// 「对不上」的告知 —— 底部固定面的数据源；判定在 `ResyncNoticeState`。
    private(set) var notice: ResyncNotice?
    /// 正在生成的回复（流式输出）；没有进行中的 attempt 就是空串。
    private(set) var transientText = ""
    /// 正在往回翻页 —— 与状态行分开：界面要的是「顶部在等」。
    private(set) var isPagingOlder = false
    /// 上下文占用；`nil` 时格子显示 `--` 而不消失（消失会让模型格横移）。
    private(set) var usage: UsagePayload? = nil
    /// 最后一次收到数据帧的时刻。**不参与观察**：每帧都变，被追踪会让合并刷新失效。
    @ObservationIgnored
    private(set) var lastFrameAt: Date? = nil
    /// 每收到一条实时事件就叫一声，参数是它的类型。**单读者**：权限那一格靠它判断
    /// 「宿主那边的当前权限可能变了」。判定住在权限域（`PermissionState.affectsCurrent`），
    /// 这里只转发 —— 事件名是权限域的知识，不是编排的。
    var onLiveEventType: ((String) -> Void)?

    // MARK: - 三样共享的状态与两族动作

    /// 状态行 —— 三族动作共写同一条，所以它是一个持有者而不是三份拷贝。
    let statusBox: SessionStatus
    /// 当前显示的模型 —— 读写两侧共写同一个镜像。
    let models: SessionModelMirror
    /// 用户动作（发消息 / 命令 / 选模型）。
    let actions: SessionActions
    /// 本屏那一条流的开关。**惰性**：它的三个闭包都要捕获本对象，而在 `init` 里
    /// 捕获 `self` 要等全部存储属性就位 —— 惰性让「就位」发生在第一次用到时。
    @ObservationIgnored
    private lazy var followingStorage = SessionFollowing(
        makeStream: { [unowned self] in
            self.factory.makeStream(SessionBehavior(owner: self))
        },
        isTranscriptEmpty: { [unowned self] in self.mirror.isEmpty },
        syncNow: { [unowned self] in await self.sync() }
    )
    var following: SessionFollowing { followingStorage }

    // MARK: - 视图读的三个面（转发，不改视图的调用形状）

    /// 状态行。类型别名让 `Display/SyncText.swift` 的句子继续挂在 `SessionSync.Status` 上。
    typealias Status = SessionStatus.Value
    typealias Step = SessionStatus.Step
    typealias Cause = SessionStatus.Cause

    var status: Status { statusBox.value }
    /// 当前显示的模型：状态机的镜像，经既有的刷新路径冒泡。
    var displayedModel: ModelSelection? { models.displayed }

    private let client: RpcClient
    let sessionId: String
    /// 造流口 —— 窄接口，连接级动作在此写不出来。
    private let factory: any StreamFactory
    /// 内存里的镜像；视图重建即重取窗口。
    private var mirror = SessionMirror()
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()

    /// 连接阶段 —— 读穿而不是镜像，观察机制会跟到源头。
    var phase: ConnectionPhase { connectionPhase() }
    private let connectionPhase: () -> ConnectionPhase
    private var transient = TransientChannel()

    /// 事件 → 显示节点。它跨刷新保留 —— 状态与去重理由见 `TranscriptAssembler`。
    private var assembler = TranscriptAssembler { type in
        // 上游加了新的事件类型 —— 会话照常显示，这里留一条痕。
        // 措辞点明范围：不认识的只是**正文组装**这一层，消息流本身是认识的
        // （`model/selection` 这类还另有消费者）。
        Log.warn(Log.Module.session, "正文组装跳过不认识的事件类型：\(type)（会话照常显示）")
    }
    /// 占用值的吸收，判定在 `UsageState`。
    private var usageState = UsageState()
    /// 刷新合并闸：事件帧批处理，判定在值类型 `RefreshGate`。
    private var refreshGate = RefreshGate()
    /// flush 是否已有一次调度在途（防重复调度）。
    private var flushScheduled = false
    /// 合并窗口 = 一个渲染帧量级。未定稿内容逐帧到达无感知；事件文本晚一帧出现。
    private static let flushWindowNanos: UInt64 = 16_000_000

    init(client: RpcClient, sessionId: String, link: LongConnection) {
        self.client = client
        self.sessionId = sessionId
        self.factory = link
        self.connectionPhase = { [weak link] in link?.phase ?? .idle }

        let statusBox = SessionStatus()
        let models = SessionModelMirror()
        self.statusBox = statusBox
        self.models = models
        self.actions = SessionActions(client: client, sessionId: sessionId,
                                      status: statusBox, models: models)
    }

    // MARK: - 用户动作（转给写侧）

    /// 把一行字送出去 —— 走哪条路由 `ComposerState` 判好交进来。
    func deliver(_ dispatch: SlashDispatch) async -> Bool {
        await actions.deliver(dispatch)
    }

    /// 安装一次会话级选择。
    func selectModel(_ selection: ModelSelection) async {
        await actions.selectModel(selection)
    }

    // MARK: - 流的开关（转给流开关）

    func startFollowing() { following.start() }
    func retry() { following.retry() }
    func stopFollowing() { following.stop() }

    // MARK: - 读侧编排

    /// 同步一次：空则先取窗口，然后从末尾追到最新。幂等。
    func sync() async {
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        // 与 `loadOlder` 对照用：debug 级，`DSH_LOG_DEBUG=1` 才出来（这条可能一秒一次）。
        Log.debug(Log.Module.session, "sync start events=\(mirror.events.count) empty=\(mirror.isEmpty)")
        statusBox.set(.syncing)

        var added = 0
        var recovered = false

        // 打开会话：手里什么都没有时，先向服务端要一个最新的窗口。
        if mirror.isEmpty {
            switch await openLatest() {
            case .merged(let count):
                added += count
            case .caughtUp:
                break
            case .resetRequired:
                // 窗口本身对不上，没有比它更早的状态可退。
                mirror.reset()
                recovered = true
            case .refused(let code):
                statusBox.set(.failed(step: .opening, cause: .refusal(code: code)))
                refreshView()
                return
            case .failed:
                statusBox.set(.failed(step: .opening, cause: .transport))
                refreshView()
                return
            }
        }

        // 追新增：从镜像的末尾一直拉到服务端没有更多。
        while true {
            guard mirror.beginRequest() else { break }
            let outcome = await fetchSnapshot()
            let more = hasMore(in: outcome)

            switch mirror.apply(outcome) {
            case .merged(let count):
                added += count

            case .caughtUp:
                break

            case .resetRequired(let reason):
                // 重置只做一次：再要求重置说明不会收敛。
                guard !recovered else {
                    statusBox.set(.failed(step: .syncing, cause: .resetLoop(reason)))
                    refreshView()
                    return
                }
                recovered = true
                mirror.reset()
                // 编排自己执行的重置：保留无法收敛，一律重置并如实记「已重置」。
                noteReset(reason)
                statusBox.set(.done(added: added, recovered: true))
                refreshView()
                return

            case .refused(let code):
                statusBox.set(.failed(step: .syncing, cause: .refusal(code: code)))
                refreshView()
                return

            case .failed:
                // 传输失败：视图保持原样，只把状态说清楚。
                statusBox.set(.failed(step: .syncing, cause: .transport))
                refreshView()
                return
            }

            if !more { break }
        }

        // 干净走完 = 已对齐，「未接上」到此为止。
        clearNotice()
        statusBox.set(.done(added: added, recovered: recovered))
        refreshView()
    }

    /// 往回翻一段更早的历史；一页没有可显示的内容时接着往前（上限 3 页）。
    func loadOlder() async {
        guard !syncInFlight, mirror.hasOlder else { return }
        // 翻页低频，打 info：真机上要能对照「我没点它却加载了」。
        Log.info(Log.Module.session,
                 "loadOlder fromSeq=\(mirror.pageStart) events=\(mirror.events.count)")
        syncInFlight = true
        isPagingOlder = true
        defer {
            syncInFlight = false
            isPagingOlder = false
        }
        statusBox.set(.syncing)

        // 上限 3 页：再多说明服务端在挤牙膏，让用户看见状态行比继续闷拉更有用。
        for _ in 0..<3 {
            let nodesBefore = nodes.count
            guard let verdict = await fetchOlderPage() else { return }

            switch verdict {
            case .merged(let count):
                statusBox.set(.done(added: count, recovered: false))
            case .caughtUp:
                statusBox.set(.done(added: 0, recovered: false))
            case .resetRequired(let reason):
                // 更早的历史接不上不影响当前视图的真实性：`.gap` 保留（清空等于
                // 用「你多点一下」换掉已读到的全部内容），只有位置被否定才清空重来。
                if reason.invalidatesLocalContent { mirror.reset() }
                observeNotice(verdict)
                refreshView()
                return
            case .refused(let code):
                statusBox.set(.failed(step: .paging, cause: .refusal(code: code)))
                refreshView()
                return
            case .failed:
                statusBox.set(.failed(step: .paging, cause: .transport))
                refreshView()
                return
            }

            refreshView()
            // 这一页真的多了可显示的东西，或者已经到日志开头 —— 收工。
            if nodes.count > nodesBefore || !mirror.hasOlder { return }
        }
    }

    /// 一次往回翻的请求。`nil` = 没拿到发起权（有在途请求）。
    private func fetchOlderPage() async -> Verdict? {
        guard mirror.beginRequest() else { return nil }
        do {
            let page = try await readPage(client, sessionId: sessionId, beforeSeq: mirror.pageStart)
            return mirror.prepend(page)
        } catch let error as RpcClientError {
            mirror.abandonRequest()
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            mirror.abandonRequest()
            return .failed
        }
    }

    // MARK: - 事件吸收

    /// 打开帧与事件帧的埋点；其余类别一个渲染帧就完了，计时只会撑大日志。
    /// 与 `apply` 分开是为了顺序：两者之差正是这一跳的耗时。
    func recordPerf(_ reading: StreamReading, bytes: Int, recv: Double, apply: Double) {
        switch reading.content {
        case .opening(let opening):
            Log.perf(Log.Module.session, PerfRecord(
                seg: .dev, t: PerfRecord.nowMs(), sessionId: opening.sessionId, seq: opening.cursor,
                fields: ["kind": .text("opening"), "devRecv": .number(recv),
                         "devApply": .number(apply), "bytes": .number(Double(bytes))]
            ))
        case .event(let event):
            Log.perf(Log.Module.session, PerfRecord(
                seg: .dev, t: PerfRecord.nowMs(), sessionId: sessionId, seq: event.seq,
                fields: ["kind": .text("event"), "devRecv": .number(recv),
                         "devApply": .number(apply), "bytes": .number(Double(bytes))]
            ))
        case .transient, .usage, .refused, .ended, .ignored:
            break
        }
    }

    /// 一帧的副作用；判读已在 `SessionStreamReader` 做完，「接下来怎么办」随 `reading.next`
    /// 回给连接层。对外开放只为 `SessionBehavior` 调用 —— 别把 `mirror`/`transient` 交出去。
    func apply(_ reading: StreamReading) {
        switch reading.content {
        case .opening(let opening):
            applyOpening(opening)
        case .event(let event):
            applyLiveEvent(event)
        case .transient(let frame):
            applyTransient(frame)
        case .usage(let snapshot):
            applyUsage(snapshot)
        case .refused(let failure):
            handleStreamRefusal(failure)
        case .ended:
            // 收尾帧本身没有副作用：重开是连接层照着 `next` 做的事。
            break
        case .ignored:
            break
        }
    }

    private func applyOpening(_ opening: OpeningFrame) {
        lastFrameAt = Date()
        // WS 自己把窗口送到了，HTTP 兜底取消，免得两秒后又拉一次。
        following.cancelFirstScreenFallback()
        // 手空着时等价于「打开」，重连时走「重对齐」：保留本地更早的部分。
        let wasEmpty = mirror.isEmpty
        let verdict = mirror.realign(with: SessionPage(opening: opening))

        // 未定稿基线：opening 里带了进行中的 attempt 就恢复流式输出，没有就清场。
        if let baseline = opening.assistantStream {
            transient.apply(baseline: parseBaseline(baseline))
        } else {
            transient = TransientChannel()
        }
        transientText = transient.text

        // 模型基线：opening 的 `model` 是进会话那一刻权威的「下一轮用什么」；不在 = 不知道。
        models.absorb(baseline: opening.model)

        // 占用基线：opening 带的这一份是**这条流上最后一个读数**，后续的 `usage` 帧只在读数
        // 变化时才来（网关拿它当基线）。不采纳它，没有新轮次的会话就永远显示 `--`，
        // 而上游投影里其实有值。水位判据仍在 `UsageState` 里 —— 重连时更旧的那份会被拒。
        if let occupancy = opening.occupancy { applyUsage(occupancy) }

        // 状态行只在首次建立窗口时更新：重连是传输层事件。
        if wasEmpty {
            statusBox.set(.done(added: addedCount(verdict), recovered: false))
        } else if case .resetRequired(let reason) = verdict {
            // 分档判在 `ResetReason.invalidatesLocalContent`，这里只执行。
            if reason.invalidatesLocalContent { mirror.reset() }
            observeNotice(verdict)
        }
        refreshView()
    }

    /// 一条判定带来的净增条数 —— 只有 `merged` 携带这个数，其余（追平 / 重置 / 拒绝 / 失败）
    /// 算 0。
    private func addedCount(_ verdict: Verdict) -> Int {
        if case .merged(let count) = verdict { return count }
        return 0
    }

    /// 收下一条判定 —— 置位规则在 `ResyncNoticeState`。
    private func observeNotice(_ verdict: Verdict) {
        noticeState.observe(verdict)
        notice = noticeState.notice
    }

    /// 编排自己重置过之后改记「已重置」（`sync()` 的收场，见 `ResyncNoticeState.didReset`）。
    private func noteReset(_ reason: ResetReason) {
        noticeState.didReset(reason)
        notice = noticeState.notice
    }

    /// 重新建立 —— 告知唯一的清除点（一次成功的重新同步、或离开再进入会话）。
    private func clearNotice() {
        noticeState.clear()
        notice = noticeState.notice
    }

    private func applyLiveEvent(_ event: SessionEvent) {
        lastFrameAt = Date()
        // 一条事件 = 一次覆盖到 seq+1 的快照；上游 gap-free 是契约，幂等照旧生效。
        let verdict = mirror.apply(.received(
            SessionSnapshot(asOfSeq: event.seq + 1, hasMore: false, events: [event])
        ))
        // 「未接上」之后事件进不来；告知要跟上现状，否则界面静止却看起来正常。
        if case .resetRequired = verdict { observeNotice(verdict) }
        // 模型选择的两类事件照同一条流进来 —— 状态机自己判水位与顺序。
        models.absorb(event: event)
        // 权限那一格只关心「当前值可能变了」那三类；哪些算，判定在权限域自己手里。
        onLiveEventType?(event.type)
        // 事件帧只标脏，批到点一次全量重算（opening / HTTP 同步路径不经闸）。
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
            self.refreshView()
        }
    }

    private func applyTransient(_ frame: JSONValue) {
        // 未定稿帧也算「数据到了」：长输出期间可能只有它在流。
        lastFrameAt = Date()
        let before = transient
        let verdict = transient.apply(frame: frame)
        if verdict == .broken {
            // 基线已丢，后续 chunk 是增量 —— 干等只会残缺，重开流取新基线。
            Log.warn(Log.Module.session, "TransientChannel broken: expected revision=\(String(describing: before.expectedRevisionDescription)) nextChunkIndex=\(before.nextIndexDescription), got type=\(frame["type"]?.string ?? "?") revision=\(String(describing: frame["revision"]?.int)) index=\(String(describing: frame["index"]?.int))")
            following.retry()
            return
        }
        transientText = transient.text
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        // 包成「抛出来的错误」：显示层会解释成「订阅流被拒绝：…」。
        statusBox.set(.failed(step: .streaming, cause: .thrown(RpcClientError.refused(failure))))
        refreshView()
    }

    /// 一份占用读数；被丢弃的帧不动视图，乱序与重放不会让百分比跳动。
    private func applyUsage(_ snapshot: UsageSnapshot) {
        // 「收到」与「采纳」是两件事：被丢弃的帧也证明链路活着，故置位在判之前。
        lastFrameAt = Date()
        guard usageState.apply(snapshot) == .accepted else { return }
        usage = usageState.usage
    }

    /// opening 的未定稿基线 → 通道的输入。只认我们声明的字段，其余忽略。
    private func parseBaseline(_ json: JSONValue) -> TransientBaseline {
        let active = json["activeAttempt"]
        return TransientBaseline(
            revision: json["revision"]?.int ?? 0,
            active: active == nil ? nil : TransientBaseline.Active(
                nextIndex: active?["nextIndex"]?.int ?? 0,
                stream: active?["stream"]?.array ?? []
            )
        )
    }

    // MARK: - 一次请求

    /// 取最新的一个窗口（打开会话）。
    private func openLatest() async -> Verdict {
        guard mirror.beginRequest() else { return .caughtUp }
        do {
            let page = try await readPage(client, sessionId: sessionId)
            return mirror.open(with: page)
        } catch let error as RpcClientError {
            mirror.abandonRequest()
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            mirror.abandonRequest()
            return .failed
        }
    }

    /// 从镜像的末尾往前拉一块。
    private func fetchSnapshot() async -> Outcome {
        do {
            let snapshot = try await readSnapshot(client, sessionId: sessionId, since: mirror.cursor)
            // snapshot 回应带着「下一轮用什么」，只有这一路能补上。
            models.absorb(baseline: snapshot.model)
            // 协议回应就是状态机的输入形状 —— 同形的东西只有一份，不在此逐字段搬。
            return .received(snapshot)
        } catch let error as RpcClientError {
            mirror.abandonRequest()
            if case .refused(let failure) = error {
                return .refused(Refusal(code: failure.code, message: failure.message))
            }
            return .transportFailed
        } catch {
            mirror.abandonRequest()
            return .transportFailed
        }
    }

    private func hasMore(in outcome: Outcome) -> Bool {
        if case .received(let snapshot) = outcome { return snapshot.hasMore }
        return false
    }

    /// 每次都从整段事件重算，不做增量 —— 增量写错一处就静默少一行。
    private func refreshView() {
        nodes = assembler.assemble(mirror.events)
        eventCount = mirror.events.count
        hasOlder = mirror.hasOlder
    }
}
