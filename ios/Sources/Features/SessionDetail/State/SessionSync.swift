import Foundation

/// 一个会话的**读侧**编排：把「取窗口 / 追新增 / 往回翻」接到状态机上。状态机只管判定，
/// 这里管调用顺序与失败收场：单飞、拉完为止、先窗口后增量。
///
/// 本类只做读：事件装配、占用、告知、流式未定稿；窗口与镜像经 `SessionInput` 读写。
/// 三样相邻的东西各住一处 ——
/// 状态行（`SessionStatus`）、当前模型（`SessionModelMirror`）、用户动作（`SessionActions`）、
/// 流的开关（`SessionFollowing`）。它们由本类装配并向视图转发，所以视图仍然只认识本对象。
///
/// 拆开的理由是变化触发源不同：读侧随「窗口与快照的协议」变，写侧随「产品动作的语义」变，
/// 流开关随「流的生命周期」变。合成一个类时，改任一处都要重读另外两处的上下文。
/// 用户看得见的句子住 `Display/SyncText.swift`。
@MainActor
@Observable
final class SessionSync {

    /// 屏幕上要画的东西。`snapshot` 里还留着 hidden 的节点（内容被清空但身份还在），
    /// 视图只取 `visible` —— 那一半才是「不闪」的另一半。
    private(set) var snapshot: ChatSnapshot = .empty

    /// 视图读的那一列：持久的一列 + 还没落定的那几行（乐观插入）。
    ///
    /// **排序按锚点**，不是「持久的一律在前」：乐观行落在发送那一刻的末尾，
    /// 之后到的持久事件与未定稿帧都排在它后面（它们的锚点更大）。
    var nodes: [ChatNode] {
        guard !pendingPrompts.isEmpty else { return snapshot.visibleNodes }
        return (snapshot.visibleNodes + pendingPrompts.map(\.node)).sorted { $0.anchorSeq < $1.anchorSeq }
    }

    /// 已经发出去、还没被持久事件认领的用户消息。
    ///
    /// **不进 `ConversationAssembler`**：那里的每个输入都要有 `seq`，而这一行还没有 ——
    /// 造一个伪 `seq` 会破坏单调与去重（跳号会被判成缺口，一条本地行会让整条流不可信）。
    /// 退休只有一条判据：持久 `user/message` 的 `source.rpcId` 等于这里的 `requestId`。
    struct PendingPrompt: Equatable {
        let requestId: String
        let text: String
        let time: Double
        let anchorSeq: EventOrder

        /// 渲染成一个普通的消息节点 —— 与持久的那一行同一种外观。
        var node: ChatNode {
            ChatNode(key: "pending:\(requestId)",
                     kind: "message",
                     businessId: "pending:\(requestId)",
                     anchorSeq: anchorSeq,
                     visibility: .visible,
                     data: .message(MessageNodeData(text: text, time: time)))
        }
    }

    private(set) var pendingPrompts: [PendingPrompt] = []

    /// 「持久行已经上屏」的乐观行 id —— **退休要等这一拍**。
    ///
    /// 事件到达时先记账、不删：删早了，`nodes` 会退回旧快照，那条刚发的消息消失一帧。
    /// 真正的删除在 `refreshSnapshot()` 之后（新快照里已经有持久行）。
    /// 只在 `input.append` 接受这条事件时记账 —— 跳号时持久行进不了视图，那一行要留着。
    private var settledPending: Set<String> = []

    /// 乐观行锚点的序号（只增不减）。用 `count` 会让「先发的那条退休后再发一条」撞回同一个锚点。
    private var pendingOrdinal = 0

    /// 上一次刷新之后攒下的变化。写入路径都往这里并，`refreshSnapshot` 取走。
    /// 放在视图状态而不是引擎里：引擎不知道「什么时候该上屏」，那是调度的事。
    private var pendingChange = AssemblyChange.none

    /// 消息条数 —— 持久的那一半由快照算好存着，乐观行按条数加上。
    ///
    /// 不把乐观行也塞进快照的计数：它的增删有两条路径（发出、被认领），让计数跟着它们
    /// 手工加减就是第二个真源。乐观行永远是一条消息，加一个数就够了。
    var messageCount: Int {
        snapshot.messageCount + pendingPrompts.count
    }
    /// 视图里的事件条数（消息只是其中一部分）。
    private(set) var eventCount = 0
    /// 还能往回翻吗。为真时界面给出入口。
    private(set) var hasMore = false
    /// 「对不上」的告知 —— 底部固定面的数据源；判定在 `ResyncNoticeState`。
    private(set) var notice: ResyncNotice?
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
    /// 每收到本会话的一条投影值就叫一声。**单读者**：权限那一格靠它读 `permissions.currentValue`。
    /// 与 `onLiveEventType` 同一手法 —— 判定住在权限域（`PermissionState.currentValueOf`），
    /// 这里只转发投影原文。
    var onProjectionValues: ((JSONValue) -> Void)?

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
        }
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
    /// 连接级投影流的收端（App 级一个实例，这一屏只关心本会话那份）。
    private let control: ControlStream?
    /// 投影订阅的退订 token。
    private var controlSubscription: (() -> Void)?
    /// 窗口与镜像的读写口 —— 镜像由它持有，这里只经它读窗口事实、发翻页、喂食引擎。
    let input = SessionInput()
    /// 同一时刻只允许一次读请求（翻页）。从前还要挡住「同步 + 翻页」并发 ——
    /// 同步那条路随 HTTP 兜底一起退场了。
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()

    /// 连接阶段 —— 读穿而不是镜像，观察机制会跟到源头。
    var phase: ConnectionPhase { connectionPhase() }
    private let connectionPhase: () -> ConnectionPhase
    private var transient = TransientChannel()

    /// 事件 → 节点。引擎跨刷新保留：身份表在里面，重建它就等于把所有节点的身份重来一遍。
    private var conversation = SessionSync.makeAssembler()
    /// 节点 → 屏幕上那一列（排序在这里，不在引擎里）。
    private var builder = ChatSnapshotBuilder()
    /// 已到但**还没有被点名**的定稿事件 —— 也在里面装「放弃的那一轮的定稿」。
    /// 两者都不喂给引擎：定稿要等 `end` 帧认领，放弃的那一轮本来就不该出现在屏幕上。
    private var held: [Int: SessionEvent] = [:]

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
    /// 占用值的吸收，判定在 `UsageState`。
    private var usageState = UsageState()
    /// 刷新合并闸：事件帧批处理，判定在值类型 `RefreshGate`。
    private var refreshGate = RefreshGate()
    /// flush 是否已有一次调度在途（防重复调度）。
    private var flushScheduled = false
    /// 草稿的物化是否已有一次调度在途。
    private var snapshotScheduled = false
    /// 合并窗口 = 一个渲染帧量级。未定稿内容逐帧到达无感知；事件文本晚一帧出现。
    private static let flushWindowNanos: UInt64 = 16_000_000

    init(client: RpcClient, sessionId: String, link: LongConnection, control: ControlStream? = nil) {
        self.client = client
        self.sessionId = sessionId
        self.factory = link
        self.control = control
        self.connectionPhase = { [weak link] in link?.phase ?? .idle }

        let statusBox = SessionStatus()
        let models = SessionModelMirror()
        self.statusBox = statusBox
        self.models = models
        self.actions = SessionActions(client: client, sessionId: sessionId,
                                      status: statusBox, models: models)

        // 投影订阅跟着**这一屏存在**，不跟着流的开关：订在这里，`stopFollowing` 退订。
        // 开流只管事件流 —— 这一屏还没开流时也要能显示当前模型与占用。
        subscribeControl()
    }

    // MARK: - 用户动作（转给写侧）

    /// 把一行字送出去 —— 走哪条路由 `ComposerState` 判好交进来。
    ///
    /// `.prompt` 那一支先记一条乐观行再发：`requestId` 在这里铸，于是「发出去的请求」
    /// 与「屏幕上那一行」从出生就是同一个号，落定的持久事件按它来认领。
    func deliver(_ dispatch: SlashDispatch, mode: SessionPromptRequest.Mode = .queue) async -> Bool {
        switch dispatch {
        case .command(let line):
            return await actions.executeCommand(line)
        case .prompt(let text):
            let requestId = UUID().uuidString
            pendingOrdinal += 1
            pendingPrompts.append(PendingPrompt(
                requestId: requestId,
                text: PromptDraft.normalized(text) ?? text,
                time: Date().timeIntervalSince1970 * 1000,
                // 落在最后一条持久事件之后、**首块未定稿帧之前**（那一块是末 seq + 0.5）。
                // 0.001 的步长只用来在连发时保序；同一个 frontier 下 250 条以内不会撞。
                anchorSeq: Double(max(0, input.frontier - 1)) + 0.25
                    + Double(pendingOrdinal) * 0.001
            ))
            let accepted = await actions.sendPrompt(text, requestId: requestId, mode: mode)
            if !accepted { pendingPrompts.removeAll { $0.requestId == requestId } }
            return accepted
        }
    }

    /// 安装一次会话级选择。
    func selectModel(_ selection: ModelSelection) async {
        await actions.selectModel(selection)
    }

    // MARK: - 流的开关（转给流开关）

    func startFollowing() {
        following.start()
        subscribeControl()
    }
    func retry() { following.retry() }
    func stopFollowing() {
        following.stop()
        controlSubscription?()
        controlSubscription = nil
    }

    /// 订上投影流：只收本会话那一条。退订在 `stopFollowing` —— 离屏不退会让监听表随
    /// 每次进出增长，而它持有的是弱引用，泄漏不会报错，只会让每次投影都多跑一次空转。
    private func subscribeControl() {
        guard controlSubscription == nil, let control else { return }
        controlSubscription = control.updateListeners.add { [weak self] payload in
            let (sessionId, values, _) = payload
            guard let self, sessionId == self.sessionId else { return }
            // control 是权威：水位（事件 seq）在 `ControlStream` 里已经用来挡过重放，
            // 这里不再和快照的 `asOfSeq` 比 —— 两者不是同一条轴。
            self.applyControl(UsageView.payloadOf(values))
            // 当前模型读**投影**（唯二的一格在同一个回调里顺手取走）：打开帧不再带它，
            // 切模型走 `session/selectModel`，随后变的正是这一格。
            self.models.absorb(projection: values["modelSelection"])
            self.onProjectionValues?(values)
        }
    }

    // MARK: - 读侧编排

    /// 往回翻一段更早的历史；一页没有可显示的内容时接着往前（上限 3 页）。
    func loadOlder() async {
        guard !syncInFlight, input.hasMore else { return }
        // 翻页低频，打 info：真机上要能对照「我没点它却加载了」。
        Log.info(Log.Module.session, "loadOlder",
                 ["seq": String(input.windowStart), "count": String(input.records.count)])
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
                if reason.invalidatesLocalContent { resetMirror() }
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
            if nodes.count > nodesBefore || !input.hasMore { return }
        }
    }

    /// 一次往回翻的请求。`nil` = 没拿到发起权（有在途请求）。
    private func fetchOlderPage() async -> Verdict? {
        guard input.beginRequest() else { return nil }
        do {
            let page = try await readPage(client, sessionId: sessionId,
                                          throughSeq: input.throughSeq,
                                          beforeSeq: input.windowStart)
            return input.prepend(page)
        } catch let error as RpcClientError {
            input.abandonRequest()
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            input.abandonRequest()
            return .failed
        }
    }

    /// 持久行已经在新快照里了：撤掉同 `rpcId` 的乐观行。**只从 `refreshSnapshot` 调用** ——
    /// 退休与上屏必须同一拍，否则中间那段 `nodes` 退回旧快照，消息消失一帧。
    private func retireSettledPrompts() {
        guard !settledPending.isEmpty else { return }
        let retiring = pendingPrompts.filter { settledPending.contains($0.requestId) }
        guard !retiring.isEmpty else {
            settledPending.removeAll()
            return
        }
        let ids = Set(retiring.map(\.requestId))
        pendingPrompts.removeAll { ids.contains($0.requestId) }
        settledPending.subtract(ids)
        Log.info(Log.Module.session, "optimistic prompt retired by its durable message",
                 ["count": String(retiring.count)])
    }

    // MARK: - 事件吸收

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
    /// 回给连接层。对外开放只为 `SessionBehavior` 调用 —— 别把 `input`/`transient` 交出去。
    func apply(_ reading: StreamReading) {
        switch reading.content {
        case .opening(let opening):
            applySnapshot(opening)
            applyOpeningProjections(opening.projections)
        case .event(let event):
            applyLiveEvent(event)
        case .transient(let frame):
            applyTransient(frame)
        case .refused(let failure):
            handleStreamRefusal(failure)
        case .ended:
            // 收尾帧本身没有副作用：重开是连接层照着 `next` 做的事。
            break
        case .ignored:
            break
        }
    }

    private func applySnapshot(_ snapshot: SnapshotFrame) {
        lastFrameAt = Date()
        // 打开帧里已经有了的那几条：持久事件比乐观行权威。记账即可 ——
        // 紧随其后的 `refreshView()` 会把新快照建好，再撤（撤早了会空一帧）。
        for record in snapshot.records {
            if let rpcId = record.event.data["source"]?["rpcId"]?.string {
                settledPending.insert(rpcId)
            }
        }
        // 手空着时等价于「打开」，重连时走「重对齐」：保留更早的部分。
        let wasEmpty = input.isEmpty
        let verdict = input.realign(with: SessionWindow(opening: snapshot))

        // 一条新流开始：上一代扣着没点名的定稿不再等点名 —— 要么会作为普通事件重来，
        // 要么属于已结束的那一轮。作废只是「不再等认领」，记录本身要排回队列（否则静默少一行）。
        if !held.isEmpty {
            Log.warn(Log.Module.session, "新的一条流开始，上一代未认领的定稿作废",
                     ["count": String(held.count)])
            // 作废只是「不再等点名」，记录本身还得进引擎。它们的那一批已经被 `takeFeed`
            // 取走过（当时被 `held` 滤掉了），所以必须重新排一次队。
            input.requeue(held.values.sorted { $0.seq < $1.seq })
            held.removeAll()
        }
        // 旧草稿先退役：它的 attempt 已经结束或换了人，留着会与新基线拼成两段重复文本。
        if let previous = transient.liveAttemptId {
            record(conversation.settleAssistant(attemptId: previous, settlement: nil))
        }

        // 先把持久窗口喂给引擎，再放基线事件 —— 顺序不能反：
        // 基线进的是「空引擎」，而紧接着的 refreshView 会用持久窗口重建整段，把基线抹掉。
        refreshView()

        // 未定稿基线：opening 带进行中的 attempt 就恢复草稿槽位（基线内容变成事件交给引擎），
        // 没有就清场。基线是服务端此刻的权威，本地那份一律丢掉。
        if let baseline = snapshot.assistantStream {
            for event in transient.apply(baseline: baseline, cursor: max(0, input.frontier - 1)) {
                record(conversation.append(event))
            }
            refreshSnapshot()
        } else {
            transient = TransientChannel()
        }

        // 状态行只在首次建立窗口时更新：重连是传输层事件。
        if wasEmpty {
            statusBox.set(.done(added: addedCount(verdict), recovered: false))
        } else if case .resetRequired(let reason) = verdict {
            // 分档判在 `ResetReason.invalidatesLocalContent`，这里只执行。
            if reason.invalidatesLocalContent {
                resetMirror()
                // 清空之后必须刷一次：否则屏幕留着上一段窗口的内容，而引擎已经没有它了。
                refreshView()
                // 镜像与引擎都空了，而这条流不会再送旧窗口。重开流，让服务端送一份新 opening。
                //
                // 必须留到帧处理返回之后再做：在 `applySnapshot` 里同步重开，外层随后仍拿**旧帧**的
                // `establishes` 去结算新代次，会把新开流的超时守卫当场关掉。
                Task { @MainActor [weak self] in self?.following.retry() }
            }
            observeNotice(verdict)
        }
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

    private func applyLiveEvent(_ event: SessionEvent) {
        // 落定的用户消息按 `source.rpcId` 认领乐观行 —— 只在这一处记账。
        let claimed = event.type == "user/message" ? event.data["source"]?["rpcId"]?.string : nil
        lastFrameAt = Date()
        // 上游 gap-free 是契约，重复与跳号各有一种处置（见 `SessionMirror.append`）。
        let verdict = input.append(event)
        // 跳号时持久行进不了视图，那一行不能撤 —— 否则屏幕上什么都没有，要等重连才回来。
        if let claimed, !Self.isReset(verdict), pendingPrompts.contains(where: { $0.requestId == claimed }) {
            settledPending.insert(claimed)
        }
        // 「未接上」之后事件进不来；告知要跟上现状，否则界面静止却看起来正常。
        if case .resetRequired = verdict { observeNotice(verdict) }
        // 模型选择的两类事件照同一条流进来 —— 状态机自己判水位与顺序。
        models.absorb(event: event)
        // 权限那一格只关心「当前值可能变了」那三类；哪些算，判定在权限域自己手里。
        onLiveEventType?(event.type)
        // 定稿事件先扣着：attempt 还开着时它可能是「比草稿先到」的那一份，
        // 等 `end` 帧点名再放进来（点名认领，不比较文本）。
        if Self.needsNaming(event), transient.isLive, !Self.isReset(verdict) {
            held[event.seq] = event
        }
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
            self.refreshView()
        }
    }

    private func applyTransient(_ frame: JSONValue) {
        // 未定稿帧也算「数据到了」：长输出期间可能只有它在流。
        lastFrameAt = Date()
        let before = transient
        // 小数序号要落在「最后一条持久事件之后」，所以把当前游标交给通道。
        switch transient.apply(frame: frame, cursor: max(0, input.frontier - 1)) {
        case .broken:
            // 基线已丢，后续 chunk 是增量 —— 干等只会残缺，重开流取新基线。
            Log.warn(Log.Module.session, "TransientChannel broken", [
                "expectedRevision": String(describing: before.expectedRevisionDescription),
                "nextChunk": String(before.nextIndexDescription),
                "type": frame["type"]?.string ?? "?",
                "revision": String(describing: frame["revision"]?.int),
                "index": String(describing: frame["index"]?.int),
            ])
            following.retry()

        case .consumed(let events):
            // 每条 draft 的更新都物化一次会把「每帧 O(n)」放大成「每个 chunk O(n)」。
            // 节奏由定义给：`animationFrame` 合到一帧，其余立刻。
            var change = AssemblyChange.none
            for event in events {
                change.absorb(conversation.append(event))
            }
            pendingChange.absorb(change)
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
    private func settle(_ settlement: TransientChannel.Settlement) {
        let named = settlement.seq.flatMap { held[$0] }
        if let seq = settlement.seq { held.removeValue(forKey: seq) }

        if let seq = settlement.seq {
            if let named, named.type == settlement.eventType {
                Log.debug(Log.Module.session, "定稿点名成功",
                          ["attempt": settlement.attemptId, "seq": String(seq)])
            } else if named == nil, !conversation.contains(order: Double(seq)) {
                // 认领不到：草稿撤了，正式内容却没接上 —— 表现是这一轮少了一段。
                Log.warn(Log.Module.session, "定稿点名落空：草稿已撤，正式内容没接上",
                         ["attempt": settlement.attemptId, "seq": String(seq),
                          "held": String(held.count), "type": settlement.eventType ?? ""])
            } else {
                Log.warn(Log.Module.session, "定稿点名的类型对不上",
                         ["attempt": settlement.attemptId, "seq": String(seq),
                          "type": settlement.eventType ?? "", "heldType": named?.type ?? ""])
            }
        } else {
            // 放弃的那一轮不会再来点名：扣着的定稿全部作废，否则它们会被永久跳过（静默少一行）。
            if !held.isEmpty {
                Log.warn(Log.Module.session, "被放弃的一轮留下了未认领的定稿，已作废",
                         ["attempt": settlement.attemptId, "count": String(held.count)])
                // 同上一处：作废不等于丢弃，重新排队让它们作为普通事件进去。
                input.requeue(held.values.sorted { $0.seq < $1.seq })
                held.removeAll()
            }
            Log.info(Log.Module.session, "本轮被放弃：草稿已撤", ["attempt": settlement.attemptId])
        }

        record(conversation.settleAssistant(attemptId: settlement.attemptId,
                                            settlement: named.map(AssemblyEvent.init)))
        // 作废那一支刚把 `held` 排回队列，这里必须喂一次 —— 否则要等下一条事件到达
        // 才会轮到它们，而那一刻可能永远不来。`refreshView` 内含喂食与刷新。
        refreshView()
    }

    private static func isReset(_ verdict: Verdict) -> Bool {
        if case .resetRequired = verdict { return true }
        return false
    }

    /// 这个事件要不要等 `end` 帧点名：只有「这一轮还没收笔」时的定稿事件才需要。
    /// 替换型（压缩点）不是草稿的定稿，照常直接进。
    private static func needsNaming(_ event: SessionEvent) -> Bool {
        guard event.type == "assistant/message" || event.type == "assistant/attempt" else { return false }
        return event.surfaceOp?["op"]?.string != "replace"
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        // 包成「抛出来的错误」：显示层会解释成「订阅流被拒绝：…」。
        statusBox.set(.failed(step: .streaming, cause: .thrown(RpcClientError.refused(failure))))
        refreshView()
    }

    /// 一份占用读数；被丢弃的帧不动视图，乱序与重放不会让百分比跳动。
    /// control 送来的一条更新：权威，直接覆盖。
    private func applyControl(_ payload: UsagePayload?) {
        lastFrameAt = Date()
        usageState.adopt(payload)
        usage = usageState.usage
    }

    /// 打开帧的投影基线：**control 到达之前**的初值。
    ///
    /// 两条出口同源，所以这里不需要另算规则 —— 只是把同一份值先放上屏。
    /// 之后 control 的 `projection` 会按水位覆盖它（`UsageState` 只认严格更高的水位）。
    func applyOpeningProjections(_ block: ProjectionBlock) {
        applyUsage(UsageView.snapshotOf(block.values, asOfSeq: block.asOfSeq))
        // 同一块也是**这一屏的初值**：当前模型与当前权限都从这里起，control 的增量之后覆盖。
        //
        // 只在 control 上取会漏掉一种常见的顺序：control 是 App 级的、开机就订上了，
        // 而这一屏是之后才打开的 —— baseline 早已过去，于是那两格一直显示 `--`，
        // 要等一次真正的变化（切模型、切档位）才会出现。真机上「权限只剩目录」就是这个缺口。
        models.absorb(projection: block.values["modelSelection"])
        onProjectionValues?(block.values)
    }

    private func applyUsage(_ snapshot: UsageSnapshot) {
        // 「收到」与「采纳」是两件事：被丢弃的帧也证明链路活着，故置位在判之前。
        lastFrameAt = Date()
        guard usageState.apply(snapshot) == .accepted else { return }
        usage = usageState.usage
    }

    // MARK: - 一次请求

    private func refreshView() {
        feedEngine()
        refreshSnapshot()
        eventCount = input.records.count
        hasMore = input.hasMore
    }

    /// 镜像清空时引擎必须跟着清 —— 否则它保留的是上一段窗口的身份，
    /// 新窗口的事件会被判成「前插」而接到旧内容上。
    private func resetMirror() {
        // 屏幕会「整列重挂」的那个入口。记一条，否则现象只有用户看得见。
        Log.info(Log.Module.session, "镜像重置：引擎随之清空",
                 ["events": String(input.records.count), "hasMore": String(input.hasMore)])
        input.reset()
        settledPending.removeAll()
        conversation = SessionSync.makeAssembler()
        builder = ChatSnapshotBuilder()
        held.removeAll()
        transient = TransientChannel()
        // 清空变化集：不清的话，重开之后第一条追加会把上一段窗口的键一起并进来。
        pendingChange = .none
    }

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

    /// 重导次数 —— **为判据而留的读数**，与引擎那一个计同源。
    /// 它量的不是耗时，是「这次刷新碰了几格」：全量就是历史长度，增量就是变化量。
    var buildViewNodeCount: Int { conversation.buildViewNodeCount }

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
        retireSettledPrompts()
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
            held[$0.seq] == nil && !conversation.contains(order: Double($0.seq))
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
        input.records.filter { held[$0.seq] == nil }
    }
}
