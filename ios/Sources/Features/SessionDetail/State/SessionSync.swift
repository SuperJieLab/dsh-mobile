import Combine
import Foundation

/// 一个会话的同步编排：把「取窗口 / 追新增 / 往回翻」接到状态机上。状态机
/// （`SessionMirror`）只管判定，这里管调用顺序与失败收场，界面只管显示。三处纪律：
/// - **单飞**：同一会话同时只有一个同步过程（`syncInFlight`）。
/// - **拉完为止**：追新增时一块装不下就接着要，直到服务端说没有更多。
/// - **先窗口后增量**：先要一个最新窗口，再往后追 —— 于是**不需要跨会话记住任何位置**，
///   冷启动、重启、跑了一夜回来行为都一样。
///
/// 镜像只在内存里：没有任何位置或内容落盘。用 `ObservableObject` 而非 `@Observable` 宏 ——
/// 后者要跑进程外的宏插件，本项目的验证环境不允许（**能被本地编译验证，比写法新更重要**）。
///
/// 它只装两件事：编排本身，以及「把线上形状送成状态机的输入」（`parseBaseline(_:)`、
/// `refreshView` 的三条投影）—— 后者与调用顺序同源，不构成第二个变化原因。告知的置位与
/// 清除住 `ResyncNoticeState`，用户看得见的句子住 `Display/SyncText.swift`：句子若写回
/// 本文件，`LayeringTests.testStateHasNoUserFacingStrings` 会红。
@MainActor
final class SessionSync: ObservableObject {

    /// 状态行要说的事。**重置与失败必须说得出来** —— 那是用户唯一能察觉异常的地方。
    ///
    /// 失败只说「哪一步 + 哪一类原因」，不说句子：句子随产品决定变，住 `Display/SyncText.swift`
    ///。因此这个类型**不再可比较**（原因里带着抛出来的错误对象）。
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
        case executing
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
    /// 「对不上」的告知 —— 底部**固定面**的数据源。判定全在值类型里。
    ///
    /// 与 `status` 的分工：`status` 说「同步到哪了」，只在**取窗口时**更新 —— 重连是传输层
    /// 事件，不该跳它；本项说的是「有内容没能接上、或已被清空重来」—— 它要出现在**不随内容
    /// 滚动**的面上，否则用户往回翻时看不见，屏上看起来一切正常、只是少了一段。
    @Published private(set) var notice: ResyncNotice?
    /// 正在生成的回复（流式输出）；没有进行中的 attempt 就是空串。
    @Published private(set) var transientText = ""
    /// 上一次向后翻页是否还在路上。
    ///
    /// 与 `status` 分开：`status` 是「同步到哪一步」的总述，下拉刷新也会让它进 `.syncing`；
    /// 而界面要区分的是「顶部正在等更早的内容」—— 那时该在列表顶上给占位，不是给一句状态。
    @Published private(set) var isPagingOlder = false
    /// 上下文占用。为 `nil` 时占用格显示 `--` 并保持可点 —— 不消失：三格里其余两格永远有值，
    /// 这一格消失会让模型格横向挪一次。
    @Published private(set) var usage: UsagePayload? = nil
    /// 最后一次收到数据帧的时刻。`nil` = 进本屏以来还没收到过。
    ///
    /// **刻意不发布**：它每帧都变，`@Published` 会让 `RefreshGate` 的合并刷新失效
    /// （一次事件一次全量重算，那正是分帧批处理的相反面）。消费方是连接详情的 sheet，
    /// 打开那一刻读一次即可 —— 它回答的是「多久没更新」的量级，不需要逐帧跳动。
    private(set) var lastFrameAt: Date? = nil
    /// 当前显示的模型：状态机的镜像，经既有的刷新路径冒泡。
    @Published private(set) var displayedModel: ModelSelection? = nil

    private let client: GatewayClient
    private let sessionId: String
    /// 内存里的镜像。视图重建会新建一个 `SessionSync`、窗口重取一次 ——
    /// 服务端此刻给的比本地残留可信。
    private var mirror = SessionMirror()
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()

    /// 订阅流：打开会话详情即登记一条流，离屏即注销。
    ///
    /// **连接归 App**（`GatewayLink`）——这一屏只登记「我要看这个会话」，不再持有连接。
    /// 连接层交来整帧，判读在 `SessionStreamReader`（纯函数），本层只做副作用并把
    /// 「这条流接下来怎么办」回给它 —— 判据在这边、动作在那边，两边都不需要知道对方认识什么。
    ///
    /// 类型是窄接口而不是 `GatewayLink`：连接级动作（重连整条连接）在这个类型上不存在，
    /// 于是「一条流坏了去重连全部」在这里写不出来。
    private let streams: any SessionStreamHandle
    /// 连接阶段 —— 本屏读连接状态的唯一出处（功能条网络格与连接详情都读它）。
    ///
    /// 它与 `streams` 来自同一个对象，但一个是读一个是做：合成一个成员会让「读连接状态」
    /// 顺手带上「动连接」的全部能力。发布流的订阅在 `init` 里就地接上，不另存一份属性。
    @Published private(set) var phase: FollowClient.Phase = .idle
    private var transient = TransientChannel()

    /// 首屏兜底：WS 迟迟不给窗口时用 HTTP 拉一次。
    ///
    /// 这是**网络层的事** —— 用户只该看到内容出来，不该知道背后换了条通道，所以没有按钮、
    /// 没有提示、也没有「兜底中」这种状态行。WS 之后连上会走 `realign`（保留已翻出的头部、
    /// 只换尾部），不会把 HTTP 拉到的内容整段冲掉。
    private var firstScreenFallback: Task<Void, Never>?
    /// 事件 → 显示节点。它跨刷新保留 —— 状态与去重理由见 `TranscriptAssembler`。
    private var assembler = TranscriptAssembler { type in
        // 上游加了新的事件类型 —— 会话照常显示，这里留一条痕。
        Log.warn(Log.Module.session, "TranscriptAssembler 不认识的事件类型：\(type)")
    }
    /// 占用值的吸收。判定（严格高水位胜）全在值类型里，这里只持有并转发结果。
    private var usageState = UsageState()
    /// 当前模型的订阅更新。判定全在值类型里，这里只持有并转发结果。
    private var modelState = ModelSelectionState()
    /// 连接阶段变化的转发（`phase` 是它的落地处）。
    private var phaseObservation: AnyCancellable?
    /// 刷新合并闸：事件帧批处理，判定在值类型 `RefreshGate`。
    private var refreshGate = RefreshGate()
    /// flush 是否已有一次调度在途（防重复调度）。
    private var flushScheduled = false
    /// 合并窗口 = 一个渲染帧量级。未定稿内容逐帧到达无感知；事件文本晚一帧出现。
    private static let flushWindowNanos: UInt64 = 16_000_000

    init(client: GatewayClient, sessionId: String, link: GatewayLink) {
        self.client = client
        self.sessionId = sessionId
        self.streams = link
        // 只订阅、不下手：发布流就地接上，不必留一个属性给下一任读者。
        phaseObservation = link.$phase
            .sink { [weak self] phase in self?.phase = phase }
    }

    /// 下发一条指令：回包 ok = 已受理，回答本身从订阅流里来；失败如实进状态行。
    ///
    /// - Returns: 是否**已受理**。调用方据此决定清不清草稿 —— 没送到时那行字还在输入框里，
    ///   用户可以直接重按一次。
    @discardableResult
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

    /// 把一行字送出去 —— 走哪条路由 `ComposerState` 判好交进来，这里只管送。
    ///
    /// - Returns: 是否**已受理**。调用方（`ComposerState`）据此决定清不清草稿。
    @discardableResult
    func deliver(_ dispatch: SlashDispatch) async -> Bool {
        switch dispatch {
        case .command(let line): return await executeCommand(line)
        case .prompt(let text): return await sendPrompt(text)
        }
    }

    /// 执行一整行命令：回包 ok = **已受理**，执行结果本身从订阅流里的
    /// `command/run` / `command/done` 来。失败如实进状态行。
    ///
    /// 与 `sendPrompt` 分开而不是合并成一个「发一行字」的入口：两条路的**回包语义不同**
    /// （prompt 的 ok 是「进了收件箱」，命令的 ok 是「宿主开始执行」），失败的说法也不同 ——
    /// 状态行上一个是「指令没能送达」、一个是「命令没能执行」。
    ///
    /// - Returns: 是否**已受理**。`unknown-command`（名字打错 / 语法不对）是本期唯一
    ///   用户能自己改好的失败，所以那条路上草稿必须留着 —— 见调用方。
    @discardableResult
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

    /// 安装一次会话级选择：本地先记代号，回包对号落地；事件流的
    /// `model/selection` 随后照常进来 —— 与本地即时显示一致，界面不动。失败如实进状态行。
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

    /// 同步一次：镜像空着就先取一个窗口，然后从末尾追新增到最新。幂等 —— 已经是最新时
    /// 它退化成一次空增量请求。
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
                // 保留无法收敛（下一次拉到的增量仍接不上），所以它一律重置 ——
                // 告知如实记「已重置」。
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

        // 一次干净走完的同步 = 重新建立：本地与服务端已经对齐，「未接上」这件事到此为止 ——
        // 这是告知的清除点之一（另一处是离开再进入会话，视图销毁时一并消失）。
        clearNotice()
        status = .done(added: added, recovered: recovered)
        refreshView()
    }

    /// 往回翻一段更早的历史。已经翻到日志开头时什么也不做。
    ///
    /// **可能连拉几页**：一页只带回不产生显示节点的事件时（轮次边界、审批留痕），用户点了
    /// 等于什么都没发生 —— 那就接着往前，直到真拿到内容或到日志开头。服务端的 `hasOlder`
    /// 按**事件下标**算（`start > 0`），它不知道哪些事件会变成屏幕上的行，于是最后一页常常
    /// 只是一串过程事件，`hasOlder` 却还是真。
    func loadOlder() async {
        guard !syncInFlight, mirror.hasOlder else { return }
        // 翻页是低频动作，打 info：真机上要能对照「我没点，它却加载了」这种情况。
        // 日志用英文 —— State/ 层不放中文，那是用户可见句子的地盘。
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
                // 分档：取回的是一段**更早**的历史，它接不上**不影响**当前视图的真实性
                // —— 当前视图仍然完整、仍然是真的。所以 `.gap` 一律保留（清空它 = 用
                // 「你多点了一下」换掉已读到的全部内容）；只有服务端否定本地位置时才清空重来。
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
        } catch let error as GatewayClientError {
            mirror.abandonRequest()
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            mirror.abandonRequest()
            return .failed
        }
    }

    // MARK: - 订阅

    /// 进会话详情即登记一条流：服务端推 opening（首屏窗口）与后续事件，不再轮询。判定全在状态机
    /// 里 —— 与 HTTP 路径共用同一台 `SessionMirror`：
    /// - opening → `mirror.realign(with:)`（**重对齐**：本地更早的部分保留、只换尾部；
    ///   手里空着时等价于打开。重连因此不会把已经翻出来的历史还回去）
    /// - 事件帧 → `mirror.apply(.received(SessionSnapshot(asOfSeq: seq + 1, …)))` —— 一条事件就是
    ///   一次「覆盖到 seq+1 的快照」，幂等与缺口判定原样生效。
    ///
    /// 开流文本在**这一层**拼（要求：请求只在状态层里拼），编号由连接层给 —— 两者在
    /// `build` 闭包里对接：本层不知道号从哪来，连接层不认识 `op` 与会话。
    func startFollowing() {
        // `build` 只捕获会话 id（值类型），不拽住整个同步器；`handler` 是 `[weak self]`。
        // `owner` 反过来**故意**强持有：它是身份，注销时靠它比对（弱了就等于没有身份），
        // 而它在 `close(owner:)` 里随订阅一起释放 —— 泄漏的边界是这条订阅，不是本屏。
        let sessionId = self.sessionId
        streams.open(FollowClient.Subscription(
            owner: self,
            label: sessionId,
            build: { id in
                try MuxOpenFrame.following(sessionId: sessionId, streamId: id).encoded()
            },
            handler: { [weak self] envelope, raw in
                guard let self else { return StreamReply() }
                let reading = SessionStreamReader.read(envelope: envelope, raw: raw, sessionId: sessionId)
                // 到达与应用的边界要卡在这一跳的两侧：`devRecv` 是帧到手，`devApply` 是本层
                // 处理完（镜像合并、状态机吸收、刷新闸标记都在里面）。
                let recv = PerfRecord.nowMs()
                self.handle(reading)
                let apply = PerfRecord.nowMs()
                self.recordPerf(reading, bytes: raw.count, recv: recv, apply: apply)
                return StreamReply(establishes: reading.establishes, next: reading.next)
            }
        ))
        // 首屏兜底与开流成败无关：编不出帧时它是唯一还能把内容送到屏幕上的路。
        scheduleFirstScreenFallback()
    }

    /// 「重试」只重开**这一条**流：换号、在现有连接上重开，另一条流与连接本身不动。
    ///
    /// 它是流级动作，所以屏幕拿到的是它而不是重连整条连接 —— 后者会把事件流一起拽断，
    /// 而用户按的那个按钮说的是「我这一屏没内容」。
    func retry() {
        streams.reopen(owner: self)
    }

    /// 2.5 秒是「明显慢了」与「还在正常握手」的分界 —— 正常情况下 opening 一秒内到。
    /// 只在手里还是空的时候兜：已经有内容说明首屏来过，不需要第二条通道。
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
        streams.close(owner: self)
        transient = TransientChannel()
        transientText = ""
    }

    /// 打开帧与事件帧的到达/应用埋点（`kind=opening` / `kind=event`）。
    ///
    /// 只有这两类值得计时：它们各自代表「首屏窗口到手」与「一条事件落地」，延迟超标时这
    /// 两行是判断卡在哪一段的第一现场。其余类别（占用、审批、收尾）一个渲染帧就完了，
    /// 计时只会把日志撑大。
    private func recordPerf(_ reading: StreamReading, bytes: Int, recv: Double, apply: Double) {
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

    /// 一帧的副作用。判读已经在 `SessionStreamReader` 做完，这里只按结论分派。
    ///
    /// 「这条流接下来怎么办」不在这里决定 —— 它随判读结果（`reading.next`）一起回去，
    /// 由连接层执行；本方法只管屏幕上发生了什么。
    private func handle(_ reading: StreamReading) {
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
        // WS 自己把窗口送到了，HTTP 那条兜底没有存在的理由了 —— 取消掉，
        // 免得它在两秒后突然又拉一次、让视图多做一次无谓的重对齐。
        firstScreenFallback?.cancel()
        // 首次建立窗口与重连重建共用这一个入口，但语义不同：手里空着时等价于
        // 「打开」（整段取窗口）；重连时本地可能已有翻出来的历史，那时走「重对齐」——
        // 本地更早的部分原样保留，只换尾部。
        let wasEmpty = mirror.isEmpty
        let verdict = mirror.realign(with: SessionPage(opening: opening))

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
        // 一行变化；`added` 取净增，于是它不再等于整个窗口的长度。
        if wasEmpty {
            status = .done(added: addedCount(verdict), recovered: false)
        } else if case .resetRequired(let reason) = verdict {
            // 接不上：本地与新版之间有洞、或位置被否定。怎么分档、为什么这样分，
            // 判在 `ResetReason.invalidatesLocalContent` 上；这里只按它的结论执行。
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

    /// 订阅路径（opening / 往回翻）收下一条判定 —— 置位规则在值类型里
    /// （`.gap` 保留、「位置被否定」重置）。
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
        // 一条事件 = 一次覆盖到 seq+1 的快照；上游 gap-free 是契约（网关另有目击），幂等照旧生效。
        // 这是**合成**一份新快照（把单条事件包成「覆盖到 seq+1 的回应」），不是把同形数据
        // 从一种类型搬到另一种 —— 所以保留构造。
        let verdict = mirror.apply(.received(
            SessionSnapshot(asOfSeq: event.seq + 1, hasMore: false, events: [event])
        ))
        // 「未接上」之后事件进不来（中间有洞）。这个判定不能丢 —— 它让告知跟上现状，
        // 界面就不会一边静止、一边看起来正常。
        if case .resetRequired = verdict { observeNotice(verdict) }
        // 模型选择的两类事件照同一条流进来 —— 状态机自己判水位与顺序。
        modelState.absorb(event: event)
        displayedModel = modelState.displayed
        // 事件帧只标脏，批到点一次全量重算（opening / HTTP 同步路径不经闸）。
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
        // 未定稿帧也算「数据到了」：一轮长输出期间可能只有它在流，不看它的话
        // 连接详情会一边显示文字在长、一边说「最后收到数据：2 分钟前」。
        lastFrameAt = Date()
        let before = transient
        let verdict = transient.apply(frame: frame)
        if verdict == .broken {
            // 基线已丢，后续 chunk 是增量 —— 干等只会残缺，重开流取新基线。
            Log.warn(Log.Module.session, "TransientChannel broken: expected revision=\(String(describing: before.expectedRevisionDescription)) nextChunkIndex=\(before.nextIndexDescription), got type=\(frame["type"]?.string ?? "?") revision=\(String(describing: frame["revision"]?.int)) index=\(String(describing: frame["index"]?.int))")
            streams.reopen(owner: self)
            return
        }
        transientText = transient.text
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        // 它天然是一个「抛出来的错误」：包一层比多一个 `Cause` 档便宜 —— 显示层把
        // `localizedDescription` 解释成「订阅流被拒绝：…」，与用户已知的说法一致。
        status = .failed(step: .streaming, cause: .thrown(GatewayClientError.refused(failure)))
        refreshView()
    }

    /// 一份占用读数：opening 里的基线或后续 `usage` 帧 —— 同一处理。被丢弃的帧**不动视图**
    /// （`UsageState` 判定），故乱序与重放不会让百分比跳一下再回来。
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
        } catch let error as GatewayClientError {
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
            // opening 基线：snapshot 回应带着「下一轮用什么」——
            // 进会话前的选择客户端窗口里没有，只有这一路能补上。
            modelState.absorb(baseline: snapshot.model)
            displayedModel = modelState.displayed
            // 协议回应就是状态机的输入形状 —— 同形的东西只有一份，不在此逐字段搬。
            return .received(snapshot)
        } catch let error as GatewayClientError {
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

    /// 刷新界面可见的部分。状态机是唯一的事实来源。组装每次都从**整段事件**重算，不做
    /// 增量 —— 重算代价远低于「增量组装写错一处就静默少一行」的风险。手感真有问题时
    /// 再谈增量，那时要先有一条能证明「少了一行」的判据。
    private func refreshView() {
        messages = mirror.events.compactMap(\.displayMessage)
        nodes = assembler.assemble(mirror.events)
        eventCount = mirror.events.count
        hasOlder = mirror.hasOlder
    }
}
