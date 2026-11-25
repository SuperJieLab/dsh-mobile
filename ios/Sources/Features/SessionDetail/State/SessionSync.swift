import Foundation

/// 一个会话的**读侧**编排：把「取窗口 / 追新增 / 往回翻」接到状态机上。状态机只管判定，
/// 这里管调用顺序与失败收场：单飞、拉完为止、先窗口后增量。
///
/// 本类只做三件事：装配（把输入、投影、状态行、动作接成一个），转发视图读数，编排请求
/// （翻页与乐观行）。帧到达之后的事不在这里 —— 它在投影单元里，本类只收它八条接线。
///
/// 用户看得见的句子住 `Display/SyncText.swift`。
@MainActor
@Observable
final class SessionSync {

    /// 视图读的那一列：持久的一列 + 还没落定的那几行（乐观插入）。
    ///
    /// **排序按锚点**，不是「持久的一律在前」：乐观行落在发送那一刻的末尾，
    /// 之后到的持久事件与未定稿帧都排在它后面（它们的锚点更大）。
    var nodes: [ChatNode] {
        guard !pendingPrompts.isEmpty else { return snapshot.visibleNodes }
        return (snapshot.visibleNodes + pendingPrompts.map(\.node)).sorted { $0.anchorSeq < $1.anchorSeq }
    }

    /// 屏幕上要画的东西 —— 由投影产出，这里只转发。
    var snapshot: ChatSnapshot { projection.snapshot }

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
    /// 真正的删除在投影物化完成之后（新快照里已经有持久行）。
    /// 只在投影说「这条持久行被接受了」时记账 —— 跳号时持久行进不了视图，那一行要留着。
    private var settledPending: Set<String> = []

    /// 乐观行锚点的序号（只增不减）。用 `count` 会让「先发的那条退休后再发一条」撞回同一个锚点。
    private var pendingOrdinal = 0

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
    /// 最后一次收到数据帧的时刻，由投影记 —— 它只有观测价值，不参与观察。
    var lastFrameAt: Date? { projection.lastFrameAt }
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
    /// 输入侧（窗口、草稿、暂存、流开关）—— 这里只经它读写，不碰它的内部类型。
    let input: SessionInput
    /// 投影侧（帧的消化与物化）—— 这里只经它读写，接线在 `init` 末尾接。
    let projection: SessionProjection
    /// 同一时刻只允许一次读请求（翻页）。从前还要挡住「同步 + 翻页」并发 ——
    /// 同步那条路随 HTTP 兜底一起退场了。
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()

    /// 连接阶段 —— 转发输入单元读穿的那个闭包。
    var phase: ConnectionPhase { input.phase }

    /// 占用值的吸收，判定在 `UsageState`。
    private var usageState = UsageState()

    init(client: RpcClient, sessionId: String, link: LongConnection, control: ControlStream? = nil) {
        self.client = client
        self.sessionId = sessionId
        self.factory = link

        let statusBox = SessionStatus()
        let models = SessionModelMirror()
        self.statusBox = statusBox
        self.models = models
        self.actions = SessionActions(client: client, sessionId: sessionId,
                                      status: statusBox, models: models)

        // 输入单元在这里建，**不用惰性属性**：投影订阅随构造建立，而首屏在构造之后
        // 立刻就可能收到 control —— 推迟到第一次访问会让那一条丢掉。
        let input = SessionInput(sessionId: sessionId, control: control)
        self.input = input
        let projection = SessionProjection(sessionId: sessionId, input: input,
                                           statusBox: statusBox, models: models)
        self.projection = projection

        // 三处注入与八条接线留到存储属性全部就位之后：它们都要捕获本对象。
        input.makeStream = { [unowned self] in factory.makeStream(SessionBehavior(owner: projection)) }
        input.connectionPhase = { [weak link] in link?.phase ?? .idle }
        input.onControlValues = { [weak self] values in self?.absorbProjection(values) }

        projection.onSnapshotPublished = { [weak self] in self?.retireSettledPrompts() }
        projection.onRefreshNeeded = { [weak self] in self?.refreshView() }
        projection.onDurableRecords = { [weak self] records in self?.settleDurableRecords(records) }
        projection.onClaimedRow = { [weak self] rpcId in self?.claimRow(rpcId) }
        projection.onVerdict = { [weak self] verdict in self?.observeNotice(verdict) }
        projection.onRebuildNeeded = { [weak self] in self?.resetMirror() }
        projection.onOpeningProjections = { [weak self] block in self?.applyOpeningProjections(block) }
        projection.onLiveEventType = { [weak self] type in self?.onLiveEventType?(type) }
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

    // MARK: - 流的开关（转给输入单元）

    func startFollowing() { input.start() }
    func retry() { input.retry() }
    func stopFollowing() { input.stop() }

    /// control 送来的一条更新：权威，直接覆盖。
    ///
    /// 水位（事件 seq）在 `ControlStream` 里已经用来挡过重放，这里不再和快照的 `asOfSeq`
    /// 比 —— 两者不是同一条轴。当前模型也读**投影**（打开帧不再带它，切模型走
    /// `session/selectModel`，随后变的正是这一格）。
    private func absorbProjection(_ values: JSONValue) {
        applyControl(UsageView.payloadOf(values))
        models.absorb(projection: values["modelSelection"])
        onProjectionValues?(values)
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

    /// 持久行已经在新快照里了：撤掉同 `rpcId` 的乐观行。**只从投影的「物化完成」那一声调用** ——
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

    // MARK: - 投影那八条接线的落点

    /// 打开帧里已经有的持久行：先记账，等物化之后撤（撤早了会空一帧）。
    private func settleDurableRecords(_ records: [SessionRecord]) {
        for record in records {
            if let rpcId = record.event.data["source"]?["rpcId"]?.string {
                settledPending.insert(rpcId)
            }
        }
    }

    /// 落定的用户消息要认领的是不是本屏的乐观行 —— 「是哪一条」由投影判，「有没有这条」由这里判。
    private func claimRow(_ rpcId: String) {
        guard pendingPrompts.contains(where: { $0.requestId == rpcId }) else { return }
        settledPending.insert(rpcId)
    }

    /// 收下一条判定 —— 置位规则在 `ResyncNoticeState`。
    private func observeNotice(_ verdict: Verdict) {
        noticeState.observe(verdict)
        notice = noticeState.notice
    }

    /// 一份占用读数；被丢弃的帧不动视图，乱序与重放不会让百分比跳动。
    /// control 送来的一条更新：权威，直接覆盖。
    private func applyControl(_ payload: UsagePayload?) {
        projection.noteFrame()
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
        projection.noteFrame()
        guard usageState.apply(snapshot) == .accepted else { return }
        usage = usageState.usage
    }

    // MARK: - 一次请求

    /// 刷一屏：投影喂食与物化，这里补上两个窗口读数。
    ///
    /// 两个计数留在这一侧（它们是「窗口的计数」，与投影产出的快照不是一回事）；
    /// 投影内部要刷屏时经 `onRefreshNeeded` 绕回这里 —— 否则计数会停在旧值。
    private func refreshView() {
        projection.refresh()
        eventCount = input.records.count
        hasMore = input.hasMore
    }

    /// 位置被否定：镜像、乐观行、引擎、暂存、草稿一起重来。
    ///
    /// **七步的顺序是本方法唯一的正确性来源**：镜像先清（不清的话，新窗口的事件会被判成
    /// 前插接到旧内容上），乐观行接着清，引擎与 builder 与变化集连续重建，最后才是暂存与草稿。
    /// 投影只提供 `rebuild()` 那一步 —— 顺序不跨文件维护。
    private func resetMirror() {
        // 屏幕会「整列重挂」的那个入口。记一条，否则现象只有用户看得见。
        Log.info(Log.Module.session, "镜像重置：引擎随之清空",
                 ["events": String(input.records.count), "hasMore": String(input.hasMore)])
        input.reset()
        settledPending.removeAll()
        projection.rebuild()
        input.clearHeld()
        input.resetTransient()
    }

    /// 重导次数 —— **为判据而留的读数**，与引擎那一个计同源。
    var buildViewNodeCount: Int { projection.buildViewNodeCount }
}
