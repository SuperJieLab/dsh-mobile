import Foundation

/// 一个会话的**读侧**编排：把「取窗口 / 追新增 / 往回翻」接到状态机上。状态机只管判定，
/// 这里管调用顺序与失败收场：单飞、拉完为止、先窗口后增量。
///
/// 本类只做三件事：装配（把输入、投影、状态行、动作接成一个），转发视图读数，编排请求
/// （翻页与乐观行）。帧到达之后的事不在这里 —— 它在投影单元里，本类只收它九条接线与读数单元的两条。
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
        guard !optimist.entries.isEmpty else { return snapshot.visibleNodes }
        return (snapshot.visibleNodes + optimist.entries.map(\.node)).sorted { $0.anchorSeq < $1.anchorSeq }
    }

    /// 屏幕上要画的东西 —— 由投影产出，这里只转发。
    var snapshot: ChatSnapshot { projection.snapshot }

    /// 消息条数 —— 持久的那一半由快照算好存着，乐观行按条数加上。
    ///
    /// 不把乐观行也塞进快照的计数：它的增删有两条路径（发出、被认领），让计数跟着它们
    /// 手工加减就是第二个真源。乐观行永远是一条消息，加一个数就够了。
    var messageCount: Int {
        snapshot.messageCount + optimist.count
    }
    /// 下面六格都由读数单元持有，这里只转发 —— 视图的调用形状一个字不动。
    var eventCount: Int { readings.eventCount }
    var hasMore: Bool { readings.hasMore }
    var notice: ResyncNotice? { readings.notice }
    var isPagingOlder: Bool { readings.isPagingOlder }
    var usage: UsagePayload? { readings.usage }
    /// 最后一次收到数据帧的时刻 —— 只有观测价值，不参与观察。
    var lastFrameAt: Date? { readings.lastFrameAt }
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

    let sessionId: String
    /// 造流口 —— 窄接口，连接级动作在此写不出来。
    private let factory: any StreamFactory
    /// 输入侧（窗口、草稿、暂存、流开关）—— 这里只经它读写，不碰它的内部类型。
    let input: SessionInput
    /// 投影侧（帧的消化与物化）—— 这里只经它读写，接线在 `init` 末尾接。
    let projection: SessionProjection
    /// 乐观行（发出去还没落定的那几行，以及「已上屏待退休」的记账）。
    let optimist: SessionOptimist
    /// 读数与翻页（六个读口、状态行的翻页那几处、占用水位、告知）。
    let readings: SessionReadings
    /// 连接阶段 —— 转发输入单元读穿的那个闭包。
    var phase: ConnectionPhase { input.phase }

    init(client: RpcClient, sessionId: String, link: LongConnection, control: ControlStream? = nil) {
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
        // 锚点要现取窗口前沿，所以注入一个读闭包而不是一个值。
        let optimist = SessionOptimist(frontier: { [weak input] in input?.frontier ?? 0 })
        self.optimist = optimist
        let readings = SessionReadings(client: client, sessionId: sessionId,
                                       input: input, statusBox: statusBox)
        self.readings = readings

        // 三处注入与八条接线留到存储属性全部就位之后：它们都要捕获本对象。
        // 经 `self.projection` 取，不能捕那个局部常量：局部会被闭包强持，而投影强持输入单元，
        // 两者就成一环（`testTheScreenStateDiesWithTheCoordinator` 守这条）。
        input.makeStream = { [unowned self] in factory.makeStream(SessionBehavior(owner: self.projection)) }
        input.connectionPhase = { [weak link] in link?.phase ?? .idle }
        input.onControlValues = { [weak self] values in self?.absorbProjection(values) }

        projection.onSnapshotPublished = { [weak optimist] in optimist?.retire() }
        projection.onRefreshNeeded = { [weak self] in self?.refreshView() }
        projection.onDurableRecords = { [weak optimist] records in optimist?.noteDurable(records) }
        projection.onClaimedRow = { [weak optimist] rpcId in optimist?.noteClaimed(rpcId) }
        projection.onVerdict = { [weak readings] verdict in readings?.noteVerdict(verdict) }
        projection.onDataFrame = { [weak readings] in readings?.noteFrame() }
        projection.onRebuildNeeded = { [weak self] in self?.resetMirror() }
        projection.onOpeningProjections = { [weak self] block in self?.applyOpeningProjections(block) }
        projection.onLiveEventType = { [weak self] type in self?.onLiveEventType?(type) }
        readings.onRefreshNeeded = { [weak self] in self?.refreshView() }
        readings.onRebuildNeeded = { [weak self] in self?.resetMirror() }
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
            // 文本归一化与毫秒时刻留在这一侧：它们与「发送」同一处，单元不必认识 `PromptDraft`。
            optimist.insert(text: PromptDraft.normalized(text) ?? text,
                            requestId: requestId,
                            time: Date().timeIntervalSince1970 * 1000)
            let accepted = await actions.sendPrompt(text, requestId: requestId, mode: mode)
            if !accepted { optimist.remove(requestId: requestId) }
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
        readings.noteUsage(UsageView.payloadOf(values))
        models.absorb(projection: values["modelSelection"])
        onProjectionValues?(values)
    }

    // MARK: - 读侧编排

    /// 往回翻一段更早的历史 —— 判定与循环都在读数单元里，这里只把「视图有几条」交过去。
    func loadOlder() async {
        await readings.loadOlder(visibleNodeCount: { nodes.count })
    }

    // MARK: - 投影那几条接线的落点

    /// 打开帧的投影基线：**control 到达之前**的初值。
    ///
    /// 两条出口同源，所以这里不需要另算规则 —— 只是把同一份值先放上屏。
    /// 之后 control 的 `projection` 会按水位覆盖它（读数的判定器只认严格更高的水位）。
    func applyOpeningProjections(_ block: ProjectionBlock) {
        readings.applyUsage(UsageView.snapshotOf(block.values, asOfSeq: block.asOfSeq))
        // 同一块也是**这一屏的初值**：当前模型与当前权限都从这里起，control 的增量之后覆盖。
        //
        // 只在 control 上取会漏掉一种常见的顺序：control 是 App 级的、开机就订上了，
        // 而这一屏是之后才打开的 —— baseline 早已过去，于是那两格一直显示 `--`，
        // 要等一次真正的变化（切模型、切档位）才会出现。真机上「权限只剩目录」就是这个缺口。
        models.absorb(projection: block.values["modelSelection"])
        onProjectionValues?(block.values)
    }

    // MARK: - 一次请求

    /// 刷一屏：投影喂食与物化，随后把两个窗口读数交给读数单元重算。
    ///
    /// **一条边同时管两件事**：物化与计数必须同一拍，否则视图会读到「新快照配旧条数」，
    /// 而这类错只在切屏那一帧可见；投影与读数单元各自要刷屏时都经 `onRefreshNeeded`
    /// 绕回这里 —— 读数单元不持投影，它请人代劳。
    private func refreshView() {
        projection.refresh()
        readings.refreshCounts()
    }

    /// 位置被否定：镜像、乐观行、引擎、暂存、草稿一起重来。
    ///
    /// **七步的顺序是本方法唯一的正确性来源**：镜像先清（不清的话，新窗口的事件会被判成
    /// 前插接到旧内容上），乐观行**只清「已上屏待退休」那本账、行本身留着**，引擎与 builder
    /// 与变化集连续重建，最后才是暂存与草稿。
    /// 投影只提供 `rebuild()` 那一步 —— 顺序不跨文件维护。
    private func resetMirror() {
        // 屏幕会「整列重挂」的那个入口。记一条，否则现象只有用户看得见。
        Log.info(Log.Module.session, "镜像重置：引擎随之清空",
                 ["events": String(input.records.count), "hasMore": String(input.hasMore)])
        input.reset()
        optimist.clearSettled()
        projection.rebuild()
        input.clearHeld()
        input.resetTransient()
    }

    /// 重导次数 —— **为判据而留的读数**，与引擎那一个计同源。
    var buildViewNodeCount: Int { projection.buildViewNodeCount }
}
