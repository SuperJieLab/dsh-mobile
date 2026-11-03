import Foundation

/// 一个会话的同步编排：把「取窗口 / 追新增 / 往回翻」接到状态机上。状态机只管判定，
/// 这里管调用顺序与失败收场：单飞、拉完为止、先窗口后增量。
/// 用户看得见的句子住 `Display/SyncText.swift`。
@MainActor
@Observable
final class SessionSync {

    /// 状态行要说的事 —— 只报「哪一步 + 哪一类原因」，句子在 `Display/SyncText.swift`。
    enum Status {
        case idle
        case syncing
        case done(added: Int, recovered: Bool)
        case failed(step: Step, cause: Cause)
    }

    /// 失败发生在哪一步 —— 每步各有一句说法。
    enum Step {
        case opening
        case paging
        case syncing
        case sending
        case executing
        case selecting
        case streaming
    }

    /// 失败属于哪一类 —— 按「谁说的」分，不按 `RpcClientError` 的 case 分。
    enum Cause {
        /// 镜像只说「没成」：取窗口 / 追新增 / 往回翻的传输失败都没有错误对象。
        case transport
        /// 服务端按信封拒绝，但镜像只留了协议码。
        case refusal(code: String)
        /// 编排自己执行的重置撞上了缺口，连着两次。
        case resetLoop(ResetReason)
        /// 抛出来的错误原样带过去：编排查不出它属于哪一类，也不需要查 —— 显示层会解释。
        case thrown(any Error)
    }

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
    private(set) var status: Status = .idle
    /// 「对不上」的告知 —— 底部固定面的数据源；判定在 `ResyncNoticeState`。
    private(set) var notice: ResyncNotice?
    /// 正在生成的回复（流式输出）；没有进行中的 attempt 就是空串。
    private(set) var transientText = ""
    /// 正在往回翻页 —— 与 `status` 分开：界面要的是「顶部在等」。
    private(set) var isPagingOlder = false
    /// 上下文占用；`nil` 时格子显示 `--` 而不消失（消失会让模型格横移）。
    private(set) var usage: UsagePayload? = nil
    /// 最后一次收到数据帧的时刻。**不参与观察**：每帧都变，被追踪会让合并刷新失效。
    @ObservationIgnored
    private(set) var lastFrameAt: Date? = nil
    /// 当前显示的模型：状态机的镜像，经既有的刷新路径冒泡。
    private(set) var displayedModel: ModelSelection? = nil
    /// 每收到一条实时事件就叫一声，参数是它的类型。**单读者**：权限那一格靠它判断
    /// 「宿主那边的当前权限可能变了」。判定住在权限域（`PermissionState.affectsCurrent`），
    /// 这里只转发 —— 事件名是权限域的知识，不是编排的。
    var onLiveEventType: ((String) -> Void)?

    private let client: RpcClient
    let sessionId: String
    /// 内存里的镜像；视图重建即重取窗口。
    private var mirror = SessionMirror()
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()

    /// 造流口 —— 窄接口，连接级动作在此写不出来。
    private let factory: any StreamFactory
    /// 本屏那一条流。关它、重开它都是它自己的方法 —— 连接与别的流不动。
    private var stream: LogicalStream?
    /// 连接阶段 —— 读穿而不是镜像，观察机制会跟到源头。
    var phase: ConnectionPhase { connectionPhase() }
    private let connectionPhase: () -> ConnectionPhase
    private var transient = TransientChannel()

    /// 首屏兜底：WS 迟迟不给窗口时用 HTTP 拉一次，`opening` 到达即取消。
    private var firstScreenFallback: Task<Void, Never>?
    /// 事件 → 显示节点。它跨刷新保留 —— 状态与去重理由见 `TranscriptAssembler`。
    private var assembler = TranscriptAssembler { type in
        // 上游加了新的事件类型 —— 会话照常显示，这里留一条痕。
        Log.warn(Log.Module.session, "TranscriptAssembler 不认识的事件类型：\(type)")
    }
    /// 占用值的吸收，判定在 `UsageState`。
    private var usageState = UsageState()
    /// 当前模型的订阅更新，判定在 `ModelSelectionState`。
    private var modelState = ModelSelectionState()
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
    }

    /// 下发一条指令；返回「是否已受理」，调用方据此决定清不清草稿。
    private func sendPrompt(_ text: String) async -> Bool {
        // 与发送按钮的置灰读同一份判定 —— 「判空」与「取值」同源。
        guard let trimmed = PromptDraft.normalized(text) else { return false }
        do {
            try await promptSession(
                client, sessionId: sessionId, text: trimmed, promptId: UUID().uuidString
            )
            return true
        } catch {
            status = .failed(step: .sending, cause: .thrown(error))
            refreshView()
            return false
        }
    }

    // MARK: - 命令

    /// 把一行字送出去 —— 走哪条路由 `ComposerState` 判好交进来。
    func deliver(_ dispatch: SlashDispatch) async -> Bool {
        switch dispatch {
        case .command(let line): return await executeCommand(line)
        case .prompt(let text): return await sendPrompt(text)
        }
    }
    /// 执行一整行命令；回包 ok = 已受理，结果从订阅流来。
    private func executeCommand(_ line: String) async -> Bool {
        do {
            try await runCommand(client, sessionId: sessionId, line: line)
            return true
        } catch {
            status = .failed(step: .executing, cause: .thrown(error))
            refreshView()
            return false
        }
    }

    // MARK: - 模型选择

    /// 安装一次会话级选择：本地先记代号，回包对号落地。
    func selectModel(_ selection: ModelSelection) async {
        let generation = modelState.beginSelect()
        do {
            let selected = try await installModelSelection(
                client, sessionId: sessionId, selection: selection
            )
            if modelState.settle(generation: generation, selected: selected) {
                displayedModel = modelState.displayed
            }
        } catch {
            status = .failed(step: .selecting, cause: .thrown(error))
        }
    }

    /// 同步一次：空则先取窗口，然后从末尾追到最新。幂等。
    func sync() async {
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        // 与 `loadOlder` 对照用：debug 级，`DSH_LOG_DEBUG=1` 才出来（这条可能一秒一次）。
        Log.debug(Log.Module.session, "sync start events=\(mirror.events.count) empty=\(mirror.isEmpty)")
        status = .syncing

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
                status = .failed(step: .opening, cause: .refusal(code: code))
                refreshView()
                return
            case .failed:
                status = .failed(step: .opening, cause: .transport)
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
                    status = .failed(step: .syncing, cause: .resetLoop(reason))
                    refreshView()
                    return
                }
                recovered = true
                mirror.reset()
                // 编排自己执行的重置：保留无法收敛，一律重置并如实记「已重置」。
                noteReset(reason)
                status = .done(added: added, recovered: true)
                refreshView()
                return

            case .refused(let code):
                status = .failed(step: .syncing, cause: .refusal(code: code))
                refreshView()
                return

            case .failed:
                // 传输失败：视图保持原样，只把状态说清楚。
                status = .failed(step: .syncing, cause: .transport)
                refreshView()
                return
            }

            if !more { break }
        }

        // 干净走完 = 已对齐，「未接上」到此为止。
        clearNotice()
        status = .done(added: added, recovered: recovered)
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
        status = .syncing

        // 上限 3 页：再多说明服务端在挤牙膏，让用户看见状态行比继续闷拉更有用。
        for _ in 0..<3 {
            let nodesBefore = nodes.count
            guard let verdict = await fetchOlderPage() else { return }

            switch verdict {
            case .merged(let count):
                status = .done(added: count, recovered: false)
            case .caughtUp:
                status = .done(added: 0, recovered: false)
            case .resetRequired(let reason):
                // 更早的历史接不上不影响当前视图的真实性：`.gap` 保留（清空等于
                // 用「你多点一下」换掉已读到的全部内容），只有位置被否定才清空重来。
                if reason.invalidatesLocalContent { mirror.reset() }
                observeNotice(verdict)
                refreshView()
                return
            case .refused(let code):
                status = .failed(step: .paging, cause: .refusal(code: code))
                refreshView()
                return
            case .failed:
                status = .failed(step: .paging, cause: .transport)
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

    // MARK: - 订阅

    /// 进会话详情即登记一条流：opening 与事件帧都喂给同一台 `SessionMirror`
    /// （opening 走 `realign`：本地更早的部分保留、只换尾部）。
    /// 开流文本在这一层拼，编号由连接层给。
    func startFollowing() {
        // 一次屏幕只造一条：重复调用不换号、也不多一条流（视图重算会让这里被调多次）。
        guard stream == nil else { return }
        stream = factory.makeStream(SessionBehavior(owner: self))
        // 首屏兜底与开流成败无关：编不出帧时它是唯一还能把内容送到屏幕上的路。
        scheduleFirstScreenFallback()
    }

    /// 只重开这一条流 —— 流级动作，不动连接与别的流。
    func retry() {
        stream?.restart()
    }

    /// 2.5 秒是「明显慢了」与「还在握手」的分界；只在手里还空时兜。
    private func scheduleFirstScreenFallback() {
        firstScreenFallback?.cancel()
        firstScreenFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, self.mirror.isEmpty else { return }
            Log.info(Log.Module.session, "first-screen fallback: ws silent, fetching over http")
            await self.sync()
        }
    }

    /// 离开会话详情：注销这条流、清未定稿。连接留在原处（App 级），镜像随本对象消失。
    func stopFollowing() {
        firstScreenFallback?.cancel()
        firstScreenFallback = nil
        stream?.close()
        stream = nil
        transient = TransientChannel()
        transientText = ""
    }

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
        firstScreenFallback?.cancel()
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
        if let baseline = opening.model {
            modelState.absorb(baseline: baseline)
            displayedModel = modelState.displayed
        }

        // 占用基线：opening 带的这一份是**这条流上最后一个读数**，后续的 `usage` 帧只在读数
        // 变化时才来（网关拿它当基线）。不采纳它，没有新轮次的会话就永远显示 `--`，
        // 而上游投影里其实有值。水位判据仍在 `UsageState` 里 —— 重连时更旧的那份会被拒。
        if let occupancy = opening.occupancy { applyUsage(occupancy) }

        // 状态行只在首次建立窗口时更新：重连是传输层事件。
        if wasEmpty {
            status = .done(added: addedCount(verdict), recovered: false)
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
        modelState.absorb(event: event)
        displayedModel = modelState.displayed
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
            stream?.restart()
            return
        }
        transientText = transient.text
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        // 包成「抛出来的错误」：显示层会解释成「订阅流被拒绝：…」。
        status = .failed(step: .streaming, cause: .thrown(RpcClientError.refused(failure)))
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
            modelState.absorb(baseline: snapshot.model)
            displayedModel = modelState.displayed
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
