import Combine
import Foundation

/// 一个会话的同步编排：把「取窗口 / 追新增 / 往回翻」三件事接到状态机上。状态机
/// （`SessionMirror`）只管判定，这里管调用顺序与失败收场，界面只管显示。三处纪律：
/// - **单飞**：同一会话同时只有一个同步过程（`syncInFlight`）。
/// - **拉完为止**：追新增时一块装不下就接着要，直到服务端说没有更多。
/// - **先窗口后增量**：先向服务端要一个最新的窗口，再往后追 —— 这样**不需要跨会话记住任何
///   位置**，冷启动、重启、跑了一夜回来行为都一样。
///
/// 镜像只在内存里（见 `SessionMirror`）：没有任何位置或内容落盘。用 `ObservableObject`
/// 而非 `@Observable` 宏 —— 后者要跑进程外的宏插件，本项目的验证环境不允许（**能被本地
/// 编译验证，比写法新更重要**）。
///
/// **这里的第三类东西已经搬走**（R18 期2）：告知的置位与清除在 `ResyncNoticeState`（同目录），
/// 用户看得见的句子在 `Display/SyncText.swift`。仍留在这里的是编排本身与「把线上形状搬成
/// 状态机的输入」这两件（`window(_:)`、`parseBaseline(_:)`、`refreshView` 的三条投影）——
/// 它们与调用顺序同源，不构成第二个变化原因。句子若写回本文件，
/// `LayeringTests.testSyncOrchestrationHasNoUserFacingStrings` 会红。
///
/// 消费者：`SessionDetailView`（整屏与底栏）、`ModelPickerView`（读显示值与发起换模型）。
@MainActor
final class SessionSync: ObservableObject {

    /// 状态行要说的事。**重置与失败必须说得出来** —— 那是用户唯一能察觉异常的地方。
    ///
    /// 失败只说「哪一步 + 哪一类原因」，不说句子：句子随产品决定变，住 `Display/SyncText.swift`
    /// （R18 期2）。因此这个类型**不再可比较**（原因里带着抛出来的错误对象）；视图要问
    /// 「在不在同步」时读 `isSyncing` / `isIdle` 这两个形状查询。
    enum Status {
        case idle
        case syncing
        case done(added: Int, recovered: Bool)
        case failed(step: Step, cause: Cause)
    }

    /// 失败发生在哪一步。六个步骤各有一句说法 —— 同一类原因在不同步骤上说的话不一样
    /// （打开时说「这一屏还是空的」，往回翻时说「未能加载更早的消息」）。
    enum Step {
        case opening
        case paging
        case syncing
        case sending
        case selecting
        case streaming
    }

    /// 失败属于哪一类。四档按**谁说的**分，不按 `GatewayClientError` 的 case 分 ——
    /// 后者有七个，重新分类一次就多一份会漂移的对照表。
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

    /// 屏幕上要画的消息。
    @Published private(set) var messages: [DisplayMessage] = []
    /// 屏幕上要画的东西 —— 消息**与过程**；由组装器从同一批事件算出。
    @Published private(set) var nodes: [TranscriptNode] = []
    /// 视图里的事件条数（消息只是其中一部分）。
    @Published private(set) var eventCount = 0
    /// 还能往回翻吗。为真时界面给出入口。
    @Published private(set) var hasOlder = false
    @Published private(set) var status: Status = .idle
    /// 「对不上」的告知 —— 底部**固定面**的数据源（R10 期2 链路 C）。判定全在值类型里。
    ///
    /// 与 `status` 的分工：`status` 说「同步到哪了」，只在**取窗口时**更新（重连不跳它，spec 2.3.1）；
    /// 本项说的是「有内容没能接上、或已被清空重来」—— 它要出现在**不随内容滚动**的面上，
    /// 否则用户往回翻时看不见（那正是 spec 2.4.3 要防的「看起来正常但少了内容」）。
    @Published private(set) var notice: ResyncNotice?
    /// 正在生成的回复（流式输出）；没有进行中的 attempt 就是空串。
    @Published private(set) var transientText = ""
    /// 订阅流的连接阶段 —— 连接态指示器的数据源，从 `FollowClient` 转发。
    @Published private(set) var connectionPhase: FollowClient.Phase = .idle
    /// 上下文占用。为 `nil` 时界面**隐藏整行**。
    @Published private(set) var usage: UsagePayload? = nil
    /// 当前显示的模型：状态机的镜像，经既有的刷新路径冒泡。
    @Published private(set) var displayedModel: ModelSelection? = nil

    private let client: GatewayClient
    private let sessionId: String
    /// 待批审批的状态机。事实来源与镜像同一条：窗口事件里的 asked − decided 差集，
    /// 每次刷新重建。
    let approvals: ApprovalStore
    /// 内存里的镜像。视图重建会新建一个 `SessionSync`、窗口重取一次 ——
    /// 服务端此刻给的比本地残留可信。
    private var mirror = SessionMirror()
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()

    /// 订阅流：打开详情页即开启，实时收 opening / 事件 / 未定稿帧。
    private lazy var follow: FollowClient = {
        let followClient = FollowClient()
        followClient.onOpening = { [weak self] opening in self?.applyOpening(opening) }
        followClient.onEvent = { [weak self] event in self?.applyLiveEvent(event) }
        followClient.onTransient = { [weak self] frame in self?.applyTransient(frame) }
        followClient.onApproval = { [weak self] payload in self?.approvals.receive(payload) }
        followClient.onUsage = { [weak self] snapshot in self?.applyUsage(snapshot) }
        followClient.onRefused = { [weak self] failure in self?.handleStreamRefusal(failure) }
        // 连接态指示器的唯一来源：不接的话指示器永远停在 idle、`ConnectionBadge` 恒隐藏。
        followClient.onPhaseChange = { [weak self] phase in self?.connectionPhase = phase }
        // upgrade 时刻取一张有效的 access —— 没有就裸连，让服务端如实拒绝。
        followClient.authorizationProvider = { CredentialStore.shared.validAccessToken() }
        // 传输与地址每次建连现取 —— 组网激活（client.activate）后下一轮连接即走 tailnet。
        followClient.sessionProvider = { [weak self] in self?.client.meshSession ?? .shared }
        followClient.baseURLProvider = { [weak self] in self?.client.baseURL }
        return followClient
    }()
    private var transient = TransientChannel()
    /// 事件 → 显示节点。它跨刷新保留 —— 状态与去重理由见 `TranscriptAssembler`。
    private var assembler = TranscriptAssembler { type in
        // 上游加了新的事件类型 —— 会话照常显示，这里留一条痕。
        Log.warn(Log.Module.session, "TranscriptAssembler 不认识的事件类型：\(type)")
    }
    /// 占用值的吸收。判定（严格高水位胜）全在值类型里，这里只持有并转发结果。
    private var usageState = UsageState()
    /// 当前模型的订阅更新。判定全在值类型里，这里只持有并转发结果。
    private var modelState = ModelSelectionState()
    /// 把嵌套状态机的变化冒泡成自己的 objectWillChange ——
    /// 不转发的话审批卡的增删不触发视图重算（真机踩实）。
    private var approvalsObservation: AnyCancellable?
    /// 刷新合并闸（R4 决定 2）：事件帧批处理，判定在值类型 `RefreshGate`。
    private var refreshGate = RefreshGate()
    /// flush 是否已有一次调度在途（防重复调度）。
    private var flushScheduled = false
    /// 合并窗口 = 一个渲染帧量级。未定稿内容逐帧到达无感知；事件文本晚一帧出现。
    private static let flushWindowNanos: UInt64 = 16_000_000

    init(client: GatewayClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
        self.approvals = ApprovalStore(client: client)
        approvalsObservation = approvals.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// 下发一条指令：回包 ok = 已受理，回答本身从订阅流里来；失败如实进状态行，
    /// 输入的字还在框里。
    func sendPrompt(_ text: String) async {
        // 与发送按钮的置灰读同一份判定 —— 「判空」与「取值」同源（R18 期3 决定 B1）。
        guard let trimmed = PromptDraft.normalized(text) else { return }
        do {
            try await client.sendPrompt(sessionId: sessionId, text: trimmed, promptId: UUID().uuidString)
        } catch {
            status = .failed(step: .sending, cause: .thrown(error))
            refreshView()
        }
    }

    // MARK: - 模型选择

    /// 安装一次会话级选择：本地先记代号，回包对号落地；事件流的
    /// `model/selection` 随后照常进来 —— 与本地即时显示一致，界面不动。失败如实进状态行。
    func selectModel(_ selection: ModelSelection) async {
        let generation = modelState.beginSelect()
        do {
            let selected = try await client.selectModel(sessionId: sessionId, selection: selection)
            if modelState.settle(generation: generation, selected: selected) {
                displayedModel = modelState.displayed
            }
        } catch {
            status = .failed(step: .selecting, cause: .thrown(error))
        }
    }

    /// 同步一次：镜像空着就先取一个窗口，然后从末尾追新增到最新。幂等 —— 已经是最新时
    /// 它退化成一次空增量请求。
    func sync() async {
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
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
                // 重置只做一次：重置之后服务端又要求重置，说明继续拉也不会收敛，
                // 停下来说清楚比无限重试好。
                guard !recovered else {
                    status = .failed(step: .syncing, cause: .resetLoop(reason))
                    refreshView()
                    return
                }
                recovered = true
                mirror.reset()
                // 这是**编排自己**执行的重置：`sync()` 是用户显式要求的「重新同步」，撞上缺口时
                // 保留无法收敛（下一次拉到的增量仍接不上），所以它一律重置 —— 告知如实记「已重置」。
                noteReset(reason)
                // 位置已作废，没有内容可续。下一次同步会以「取窗口」的形态重来。
                status = .done(added: added, recovered: true)
                refreshView()
                return

            case .refused(let code):
                status = .failed(step: .syncing, cause: .refusal(code: code))
                refreshView()
                return

            case .failed:
                // 传输失败：视图保持原样（状态机保证），只把状态说清楚。
                status = .failed(step: .syncing, cause: .transport)
                refreshView()
                return
            }

            if !more { break }
        }

        // 一次干净走完的同步 = 重新建立：本地与服务端已经对齐，此前的「未接上」到此为止 ——
        // 这是告知的清除点之一（另一处是离开再进入会话，视图销毁时一并消失）。
        clearNotice()
        status = .done(added: added, recovered: recovered)
        refreshView()
    }

    /// 往回翻一段更早的历史。已经翻到日志开头时什么也不做。
    func loadOlder() async {
        guard !syncInFlight, mirror.hasOlder else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        status = .syncing

        guard mirror.beginRequest() else { return }

        let verdict: Verdict
        do {
            let page = try await client.page(sessionId: sessionId, beforeSeq: mirror.pageStart)
            verdict = mirror.prepend(window(page))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error {
                verdict = .refused(code: failure.code)
            } else {
                verdict = .failed
            }
        } catch {
            verdict = .failed
        }

        switch verdict {
        case .merged(let count):
            status = .done(added: count, recovered: false)
        case .caughtUp:
            status = .done(added: 0, recovered: false)
        case .resetRequired(let reason):
            // 分档（R10 期2 决定 1 / 决定 2）：取回的是一段**更早**的历史，它接不上**不影响**当前
            // 视图的真实性 —— 当前视图仍然完整、仍然是真的。所以 `.gap` 一律保留（清空它 = 用
            // 「你多点了一下」换掉用户已经读到的全部内容）；只有服务端否定了本地位置时才清空重来。
            if reason.invalidatesLocalContent { mirror.reset() }
            observeNotice(verdict)
        case .refused(let code):
            status = .failed(step: .paging, cause: .refusal(code: code))
        case .failed:
            status = .failed(step: .paging, cause: .transport)
        }

        refreshView()
    }

    // MARK: - 订阅

    /// 打开详情页即订阅：服务端推 opening（首屏窗口）与后续事件，不再轮询。判定全在状态机
    /// 里 —— 与 HTTP 路径共用同一台 `SessionMirror`：
    /// - opening → `mirror.realign(with:)`（**重对齐**：本地更早的部分保留、只换尾部；
    ///   手里空着时等价于打开。重连因此不再把翻出来的历史还回去，R10 期1）
    /// - 事件帧 → `mirror.apply(.received(Snapshot(asOfSeq: seq + 1, …)))` —— 一条事件就是
    ///   一次「覆盖到 seq+1 的快照」，幂等与缺口判定原样生效。
    func startFollowing() {
        follow.start(sessionId: sessionId)
    }

    /// 离开详情页：关流、清未定稿。镜像留在内存里（视图销毁时一起消失）。
    func stopFollowing() {
        follow.stop()
        transient = TransientChannel()
        transientText = ""
    }

    /// 回前台立即触发重连：上游「恢复立即试」的复现。已就绪或正在握手时无事发生。
    /// 只动连接编排，不碰镜像 —— 新 opening 会经 `applyOpening` 原路进来。
    func reconnectNow() {
        follow.reconnectNow()
    }

    private func applyOpening(_ opening: OpeningFrame) {
        // 首次建立窗口与重连重建共用这一个入口，但语义不同（R10 期1）：手里空着时等价于
        // 「打开」（整段取窗口）；重连时本地可能已有翻出来的历史，那时走「重对齐」——
        // 本地更早的部分原样保留，只换尾部。
        let wasEmpty = mirror.isEmpty
        let verdict = mirror.realign(with: Window(
            pageStart: opening.pageStart,
            asOfSeq: opening.cursor,
            hasOlder: opening.hasOlder,
            events: opening.events
        ))

        // 未定稿基线：opening 里带了进行中的 attempt 就恢复流式输出，没有就清场。
        if let baseline = opening.assistantStream {
            transient.apply(baseline: parseBaseline(baseline))
        } else {
            transient = TransientChannel()
        }
        transientText = transient.text

        // 模型基线：opening 的可选 `model` 字段是进会话那一刻权威的「下一轮用什么」
        // —— 状态机无条件落地（全会话投影比窗口推断权威）。字段不在 = 不知道，不猜。
        if let baseline = opening.model {
            modelState.absorb(baseline: baseline)
            displayedModel = modelState.displayed
        }

        // 状态行只在**首次建立窗口**时更新：重连是传输层事件，用户没做任何事，不该看到
        // 一行变化（spec 2.3.1）；`added` 取净增，于是它不再等于整个窗口的长度。
        if wasEmpty {
            status = .done(added: addedCount(verdict), recovered: false)
        } else if case .resetRequired(let reason) = verdict {
            // 接不上：本地与新版之间有洞、或位置被否定。分档（R10 期2 决定 1）—— 洞（`.gap`）
            // 保留本地（内容是旧的，但不是错的）；位置被否定则清空重来（留下的内容可能不是真的）。
            // 两种处置都交给告知，由它出现在**不随滚动离开**的面上（链路 C）—— 期1 那行只写进
            // footer 的状态行，用户往回翻时在屏幕外，等于没说。
            if reason.invalidatesLocalContent { mirror.reset() }
            observeNotice(verdict)
        }
        refreshView()
    }

    /// 一条判定带来的净增条数 —— 只有 `merged` 携带这个数，其余（追平 / 重置 / 拒绝 / 失败）算 0。
    private func addedCount(_ verdict: Verdict) -> Int {
        if case .merged(let count) = verdict { return count }
        return 0
    }

    /// 订阅路径（opening / 往回翻）收下一条判定 —— 置位规则在值类型里（`.gap` 保留、「位置被否定」重置）。
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
        // 一条事件 = 一次覆盖到 seq+1 的快照；上游 gap-free 是契约（网关另有目击），幂等照旧生效。
        let verdict = mirror.apply(.received(Snapshot(asOfSeq: event.seq + 1, hasMore: false, events: [event])))
        // 「未接上」之后事件进不来（中间有洞）。这个判定**不再被丢掉** —— 它让告知跟上现状，
        // 界面就不会一边静止、一边看起来正常（R10 期2 链路 C）。
        if case .resetRequired = verdict { observeNotice(verdict) }
        // 模型选择的两类事件照同一条流进来 —— 状态机自己判水位与顺序。
        modelState.absorb(event: event)
        displayedModel = modelState.displayed
        // R4 决定 2：事件帧只标脏，批到点一次全量重算（opening / HTTP 同步路径不经闸）。
        if refreshGate.eventArrived() == .openWindow { scheduleFlush() }
    }

    /// 合并刷新的调度端：批窗口 = 一个渲染帧量级（16ms，参数现定）。窗口期内
    /// 再来的事件只累计；到点关批、全量重算一次。调度与本闸的判定分离——判定
    /// 是 `RefreshGate`（CLI 可断言），这里只管睡与叫醒。
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
        let before = transient
        let verdict = transient.apply(frame: frame)
        if verdict == .broken {
            // 基线已丢，后续 chunk 是增量 —— 干等只会残缺，重开流取新基线。
            Log.warn(Log.Module.session, "TransientChannel broken: expected revision=\(String(describing: before.expectedRevisionDescription)) nextChunkIndex=\(before.nextIndexDescription), got type=\(frame["type"]?.string ?? "?") revision=\(String(describing: frame["revision"]?.int)) index=\(String(describing: frame["index"]?.int))")
            follow.reopenStream()
            return
        }
        transientText = transient.text
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        // 它天然是一个「抛出来的错误」：包一层比多一个 `Cause` 档便宜，而显示层那句
        // 「订阅流被拒绝：」正好等于搬家前的说法（`localizedDescription` 走 `.refused` 的解释）。
        status = .failed(step: .streaming, cause: .thrown(GatewayClientError.refused(failure)))
        refreshView()
    }

    /// 一份占用读数：opening 里的基线或后续 `usage` 帧 —— 同一处理。被丢弃的帧**不动视图**
    /// （`UsageState` 判定），故乱序与重放不会让百分比跳一下再回来。
    private func applyUsage(_ snapshot: UsageSnapshot) {
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
            let page = try await client.page(sessionId: sessionId)
            return mirror.open(with: window(page))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            return .failed
        }
    }

    /// 从镜像的末尾往前拉一块。
    private func fetchSnapshot() async -> Outcome {
        do {
            let snapshot = try await client.snapshot(sessionId: sessionId, since: mirror.cursor)
            // opening 基线：snapshot 回应带着「下一轮用什么」——
            // 进会话前的选择客户端窗口里没有，只有这一路能补上。
            modelState.absorb(baseline: snapshot.model)
            displayedModel = modelState.displayed
            return .received(Snapshot(
                asOfSeq: snapshot.asOfSeq,
                hasMore: snapshot.hasMore,
                events: snapshot.events
            ))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error {
                return .refused(Refusal(code: failure.code, message: failure.message))
            }
            return .transportFailed
        } catch {
            return .transportFailed
        }
    }

    private func hasMore(in outcome: Outcome) -> Bool {
        if case .received(let snapshot) = outcome { return snapshot.hasMore }
        return false
    }

    /// 网络层的窗口 → 状态机的窗口（两者形状相同，各自跟着自己的层走）。
    private func window(_ page: SessionPage) -> Window {
        Window(
            pageStart: page.pageStart,
            asOfSeq: page.asOfSeq,
            hasOlder: page.hasOlder,
            events: page.events
        )
    }

    /// 刷新界面可见的部分。状态机是唯一的事实来源。组装每次都从**整段事件**重算，不做
    /// 增量 —— 重算代价远低于「增量组装写错一处就静默少一行」的风险；真机上手感有变化时再谈。
    private func refreshView() {
        messages = mirror.events.compactMap(\.displayMessage)
        nodes = assembler.assemble(mirror.events)
        eventCount = mirror.events.count
        hasOlder = mirror.hasOlder
        approvals.rebuild(from: mirror.events)
    }
}

extension SessionSync.Status {

    /// 「现在是不是在同步」—— 形状查询，不是句子：视图拿它做分支（要不要转圈、要不要禁用）。
    /// 它随 `Status` 的形状变，所以住在类型这边，不住 `Display/`。
    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    /// 「还没开始」—— 同上。
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}
