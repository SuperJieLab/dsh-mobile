import Foundation

/**
 * 订阅流的连接编排 —— `URLSessionWebSocketTask` 上的三件事：
 *
 * 1. **代次**：本地单调计数；每次（重）连接都是新代次，旧代次回调一律丢弃 ——
 *    迟到的旧帧不能污染新代次视图。
 * 2. **退避重连**：base 500ms × 2^n、抖动 50–100%、封顶 10s，就绪硬超时 45s（取值来由见
 *    `readyTimeout`）；**重连即重新 open**，新 opening 重建窗口、不做水位续传。
 * 3. **心跳**：2s ping 一次，但**只在已成流的连接上判死** —— 还没拿到 opening 的那一段归
 *    就绪硬超时管，理由见 `livenessTick`；URLSession 自动回服务端的 ping，这里只管
 *    「对面还活着吗」。
 *
 * 本类只回答「线还在不在」：它解帧的外壳（三个字段存在与否），把整帧原样交给订阅方，再按
 * 对方回的 `StreamReply` 决定动作。它不认识 op 名、不知道流编号取几、也不认识帧类型的取值 ——
 * 要发的开流内容由订阅方**编好了交进来**（`start(streamId:label:open:)`），它只负责发出去、
 * 并在重开时重发同一段。协议名与端口全从 `GatewayClient.baseURL` 推导 —— 全 App 只有一个
 * 要改的地址。
 */
@MainActor
final class FollowClient: NSObject {

    /// 连接阶段。`waiting` 携带下一次重连前的毫秒数，界面可以如实显示。
    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case waiting(ms: Int)
    }

    // MARK: - 回调（由编排层注入；全部在主线程）

    /// 收到一帧：外壳 + 原始字节。返回值决定这条流下一步怎么办。
    ///
    /// 整帧交出去、不收分门别类的回调，是这一层的边界：多一个业务帧就多一条回调的写法，
    /// 会让它变成所有业务的交汇处。
    var onFrame: ((MuxServerEnvelope, Data) -> StreamReply)?
    /// 连接阶段变化（连接态指示器的数据源）。
    var onPhaseChange: ((Phase) -> Void)?
    /// 取一张有效的访问凭证 —— upgrade 请求带上它。**没有就说明现在不该连**：
    /// 见 `connect` 里对空票的处理。
    var authorizationProvider: (() -> String?)?
    /// 换一张票。`connect` 见空票时调它，**并且由本类自己决定下一步**（见 `renewThenRetry`）：
    /// 换到了就跳过剩余退避重连，换不到就按处境等或停。
    ///
    /// 为什么决定权在这里而不是注入方：退避重连这条路上没有别的东西会去换票（`start` 与
    /// `reconnectNow` 的前置都只在各自入口跑一次）。票过期后若照旧裸连，每一轮退避都是一次
    /// 注定被拒的握手，而且**永不收敛** —— 服务端看不到票，我们也永远拿不到新的，直到有人回
    /// 前台或重新进屏。那表现就是静默断流，不是慢一下。
    var ticketRenewer: (() async -> AccessTicket)?
    /// 建连的传输与地址每次现取：store 激活后下一轮连接即走隧道，本类零改动。
    /// 返回 nil = 端点不存在（未激活）——不猜地址，connect 据此进退避等待。
    var sessionProvider: () -> URLSession = { .shared }
    var baseURLProvider: () -> URL? = { nil }

    // MARK: - 状态

    /// 连接阶段 —— 对外由 `onPhaseChange` 转发（`SessionSync.connectionPhase`）。
    /// 通知挂在 setter 上：
    /// `connect`、开流、收到打开帧、退避等待、`stop` 五处都会改它，
    /// 手写必定漏接一处。
    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// 连接代次 —— 每次连接递增；回调带着发起时的代次，对不上就丢。
    private var generation = 0
    /// 这条连接的标识，只进日志（会话 id）—— 它区分的是「谁的第 2 代」：`g2` 在两个实例
    /// （进出详情各一个）里会重号。
    private var label: String?
    /// 要发出去的那段开流内容。由订阅方编好交进来，`reopenStream` 时重发同一段。
    private var openText: String?
    /// 本连接的流编号 —— 建成状态按它记。
    private var streamId = 0
    /// 已建成的流编号。`phase` 说连接，这个集合说每条流；第二条流介入时不会互相覆盖。
    ///
    /// 对测试可读：本层「建成」的消费点（`noteReply`）不碰 socket，值得被单独断言 ——
    /// 这段迁移错了不会编译失败，症状是心跳永不激活或退避永不归零。
    private(set) var established: Set<Int> = []
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    /// 本代连接连续未回的 pong 数 —— 随代次清零，见 `connect`。**唯一写者是心跳那一拍**
    ///（`livenessTick` 算出来的结果），别处不直接改它。
    private var missedPongs = 0
    /// 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。
    /// 心跳每拍**消费一次**（读过即清零），
    /// 理由见 `livenessTick`。
    private var heardFromPeer = false
    /// 重连定时器 —— teardown 时要能取消；同一时刻至多一个，见 `scheduleReconnect`。
    private var reconnectWorkItem: DispatchWorkItem?

    /// 就绪硬超时 —— 从**每一次开流尝试**（首连与重开，见 `armReadyTimeout`）算起，多久没等到
    /// 打开帧就当这次尝试没成。
    ///
    /// 取值 45s **不是**照抄上游的 15s（那是给快链路的）。我们的打开帧是这条流里**最大的
    /// 一帧**，而链路的吞吐可以低到 ~125 KB/s（0.51 MiB 的打开帧要传约 4.2 秒）。
    /// 网关承诺的打开帧上界是 4 MiB（`DEFAULT_LIMITS.maxOpeningBytes`），于是在最慢链路上
    /// 4 MiB ÷ 125 KB/s ≈ 34 秒，再加建连（约 2 秒）⇒ 45 秒。
    ///
    /// **这个数由「上界的尺寸」与「实测最慢吞吐」共同决定，不是拍的** —— 两端任一侧改了
    /// 上界，这个数都要跟着重算。它管的是「没建起来」，与心跳（管「建起来之后死了」）不重叠。
    static let readyTimeout: TimeInterval = 45
    private let pingInterval: TimeInterval = 2
    private let maxMissedPongs = 2

    private static let streamPath = "/rpc/stream"
    private static let baseBackoffMs = 500
    private static let maxBackoffMs = 10_000

    /// 单帧接收上限 —— 网关承诺打开帧不超过 4 MiB（网关侧
    /// `DEFAULT_LIMITS.maxOpeningBytes`），这里取它的两倍：覆盖任何非窗口帧，并留出
    /// 两端读数差异的余量。**这个属性默认只有 1 MiB**，那正是「某个会话打不开」的
    /// 成因；它必须显著大于网关的上界，否则同一个断连只是换个地方发生。
    ///
    /// 不设为 `private`：它是两端配套契约的一半，测试要能断言它。
    static let maximumMessageSize = 8 * 1024 * 1024

    /// 是否仍在订阅（`stop()` 之后一切重连都停）。
    private var following = false

    // MARK: - 生命周期

    /// 开始订阅一条流。
    ///
    /// - Parameters:
    ///   - streamId: 这条流的编号。由订阅方给 —— 编号是流的身份，不是连接的参数。
    ///   - label: 日志里用来区分实例的标识（会话 id）。本类不解释它。
    ///   - open: 要发出去的开流内容，已由订阅方编好。
    ///
    /// 重复调用同一份内容是幂等的；换流会先停旧的。
    func start(streamId newStreamId: Int, label newLabel: String, open: String) {
        if following, streamId == newStreamId, openText == open { return }
        stop()
        following = true
        streamId = newStreamId
        label = newLabel
        openText = open
        connect()
    }

    /// 停止订阅：关连接、取消一切定时器。之后不再重连。
    func stop() {
        following = false
        label = nil
        openText = nil
        established = []
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTask()
        generation += 1 // 旧代次的一切回调就此作废
        phase = .idle
    }

    /// 重开当前流：用于未定稿断号与服务端正常收尾 —— 现有连接还活着，但这一段的基线已经丢了。
    /// 重新发同一段开流内容（同一条连接上）拿新窗口；连接本身不重建。
    func reopenStream() {
        guard following, openText != nil else { return }
        sendOpen()
    }

    /// 回前台立即触发一次重连 —— 上游「恢复立即试」（online 事件 → 重连控制器）的复现。
    /// 退避窗口里的等待被跳过；已在握手或就绪的连接不受影响，不叠加并发连接。
    func reconnectNow() {
        guard following, openText != nil else { return }
        guard phase != .ready, phase != .connecting else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        Log.info(Log.Module.session, "foreground — reconnecting immediately (skipping backoff)")
        connect()
    }

    // MARK: - 连接

    private func connect() {
        guard following, openText != nil else { return }
        // 无端点（组网未激活）：不猜地址，也不动代次与 phase 的连接语义，
        // 直接进既有退避循环 —— 激活后下一轮自动连上。
        guard let endpoint = baseURLProvider() else {
            scheduleReconnect()
            return
        }
        // 注意：不在这里清零 reconnectAttempt —— 退避档位必须随失败次数爬升，
        // 否则握手持续失败时会退化成每秒一次的疯狂循环。
        generation += 1
        let current = generation
        // 心跳的判据随代次清零：连失数与「活过」的证据都不继承。上一代的欠账算到这一代
        // 头上会自锁 —— 一次没建成的连接把连失数攒到上限之后，此后每一代都在第一个心跳
        // 节拍就被判死，2 秒一转、永不恢复。
        missedPongs = 0
        heardFromPeer = false
        // 这一代还没开流，建成状态不继承：上一代的「建成」属于上一代的连接。
        established = []
        phase = .connecting
        // 连接发起时刻：与打开帧记录配对后可以算追平延迟（按代次对齐）。归属走普通字段
        // 而不是 perf 记录里的会话位 —— 本层不知道「会话」是什么，它只有一个不透明标签。
        Log.perf(Log.Module.session, PerfRecord(
            seg: .dev, t: PerfRecord.nowMs(),
            fields: ["kind": .text("connect-init"), "gen": .number(Double(current)),
                     "who": .text(label ?? "-")]
        ))

        // 上一代次的连接必须先关掉：不关的话旧 socket 的 receive/heartbeat
        // 还在（回调虽被代次拦住，连接本身泄漏），且系统的连接行为会互相干扰。
        if task !== nil {
            Log.debug(Log.Module.session, "g\(current) closing previous task before connecting")
            closeTask()
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            phase = .idle
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = Self.streamPath

        // 没有票**不裸连**：这一发必定被 401 拒。交给 `renewThenRetry` 决定下一步。
        guard let access = authorizationProvider?() else {
            Log.info(Log.Module.session, "connect g\(current) skipped — no access ticket")
            renewThenRetry()
            return
        }

        // upgrade 请求带身份：与 HTTP 同一个头、同一张票。
        var upgradeRequest = URLRequest(url: components.url!)
        upgradeRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let webSocketTask = sessionProvider().webSocketTask(with: upgradeRequest)
        // 必须在 resume 之前设：超过上限的帧会让 receive 直接以 POSIX 40 失败，
        // 而系统默认只给 1 MiB —— 一个 1.25 MB 的打开帧就足以把会话永远关在门外。
        webSocketTask.maximumMessageSize = Self.maximumMessageSize
        task = webSocketTask
        // 带上标识：`g2` 在两个实例（进出详情各一个）里会重号，
        // 只有它加上会话能区分「谁的第 2 代」。
        Log.info(Log.Module.session, "connect g\(current) [\(label ?? "-")] → \(components.url!)")
        webSocketTask.resume()

        // 握手由系统完成，开流内容立即发出（未就绪的连接会替我们排队）——
        // 服务端等的就是它：没有它，永远不会有打开帧。
        Log.debug(Log.Module.session, "g\(current) sending open for \(label ?? "-")")
        sendOpen()

        // 就绪硬超时不在这里起 —— 它挂在 `sendOpen` 上，于是「每一次开流尝试」都带时限
        //（首连与重开同路），见 `armReadyTimeout`。
        receiveLoop(on: webSocketTask, generation: current)
        heartbeat(on: webSocketTask, generation: current)
    }

    /// 在当前连接上发出开流内容，开始（或重建）这条流。
    ///
    /// 内容与外壳都不是这里造的（`openText` 由订阅方编好），本方法只决定「现在要开流」。
    private func sendOpen() {
        guard let openText else { return }
        phase = .connecting
        // 这一次尝试还没建成：旧编号的「建成」不成立，否则就绪超时与心跳都会照着旧账判。
        established.remove(streamId)
        send(text: openText)
        // 每一次开流尝试都在这里带时限 —— 首连与重开（收尾帧、`reopenStream`）走的是同一个入口。
        // 只在 `connect` 里 arm 会漏掉重开：那时「等不到打开帧」就没有任何看门人（心跳只管
        // 已成流的连接，见 `livenessTick`）。
        armReadyTimeout()
    }

    /// 就绪硬超时：从**这次开流尝试**起算，多久没等到打开帧就当它没成。
    ///
    /// ⚠️ `budget` 是**秒**，必须乘 10⁹ 转成纳秒。把秒数直接当纳秒传进去，超时会在
    /// 微秒级就到点 —— 每次连接都立即被判失败，开流帧被 cancel 成 -999，
    /// 于是永远收不到打开帧，而日志里只看到无穷无尽的「重连」。
    private func armReadyTimeout() {
        guard let webSocketTask = task else { return }
        let current = generation
        let stream = streamId
        let budget = Self.readyTimeout
        let labelForLog = label ?? "-"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard let self, self.generation == current, self.task === webSocketTask,
                  !self.established.contains(stream) else { return }
            // 这一行是「这次连接为什么没成」的第一现场：45 秒还没等到打开帧，通常意味着
            // 慢链路正传一大帧（1.25 MB 在 125 KB/s 上要传约 10 秒），或者对面根本没在
            // 服务这个会话。
            Log.warn(Log.Module.session, "g\(current) [\(labelForLog)] ready timeout (\(Int(budget))s) — closing and retrying")
            self.closeTask()
            self.scheduleReconnect()
        }
    }

    /// 关掉当前任务并使其回调作废（代次在外层管）。
    private func closeTask(from caller: String = #function) {
        if let task {
            Log.debug(Log.Module.session, "g\(generation) closeTask from \(caller)")
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
    }

    // MARK: - 收

    private func receiveLoop(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        webSocketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.task === webSocketTask else { return }
                switch result {
                case .failure(let error):
                    // 连接死了：清场走退避重连。打印具体原因 —— ATS / LNP /
                    // 路由器隔离都会在这里留下各自的错误码。
                    Log.warn(Log.Module.session, "g\(current) receive failed: \(error)")
                    self.closeTask()
                    self.scheduleReconnect()

                case .success(let message):
                    self.handleMessage(message, generation: current)
                    self.receiveLoop(on: webSocketTask, generation: current)
                }
            }
        }
    }

    /// 一帧到了：解外壳、交给订阅方、照它回的那一句话做。
    private func handleMessage(_ message: URLSessionWebSocketTask.Message, generation current: Int) {
        // 收到任何一帧都是「对端还活着」的证据 —— 由心跳那一拍消费（见 `livenessTick`）。
        // ⚠️ 它**不**等于「这条流已建成」：升级后先到的审批对账帧也算「收到过东西」，
        // 而那时打开帧的一大帧可能还在路上 —— 把它当成就绪，心跳会立刻激活、
        // 再在几拍之后把一条正在正常传输的连接判死。
        heardFromPeer = true
        guard case .string(let text) = message else {
            Log.debug(Log.Module.session, "g\(current) non-text frame ignored")
            return
        }
        let rawData = Data(text.utf8)
        guard let frame = try? JSONDecoder().decode(MuxServerEnvelope.self, from: rawData) else {
            Log.warn(Log.Module.session, "g\(current) unparsable frame (first 120 chars): \(text.prefix(120))")
            return // 解不了的帧不是消息，忽略
        }
        Log.debug(Log.Module.session, "g\(current) frame: \(frame.type)")

        // 没有订阅方就当「什么都不做」：单测里的裸实例，以及 `stop()` 之后还在路上的帧。
        let reply = onFrame?(frame, rawData) ?? StreamReply()
        noteReply(reply, streamId: frame.streamId)

        switch reply.next {
        case .keep:
            break
        case .reopen:
            // 流还在，只是不在工作了：同一条连接上重开，不动代次、不重建连接。
            guard following else { return }
            sendOpen()
        case .reconnect:
            closeTask()
            scheduleReconnect()
        case .stop:
            stop()
        }
    }

    /// 按订阅方的答复更新本层状态 —— 「建成判据由订阅方给、时机在连接层」的可执行版本。
    ///
    /// 建成即退避归零：不归零的话，握手持续失败之后即使终于成功，也会带着爬满的档位继续
    /// 退避 —— 一次成功不该被上一段失败的账拖住。
    ///
    /// 单独成方法（而不是摊在 `handleMessage` 里）是为了它能被断言：`handleMessage` 要一条
    /// 真 socket 才走得到，而这段迁移是心跳与退避的唯一输入。
    func noteReply(_ reply: StreamReply, streamId replyStreamId: Int?) {
        guard reply.establishes else { return }
        established.insert(replyStreamId ?? streamId)
        reconnectAttempt = 0
        missedPongs = 0
        phase = .ready
    }

    // MARK: - 发

    /// 发一段已经编好的文本 —— 本方法不拼协议，只负责「在代次与传输都对得上时发出去」。
    private func send(text: String) {
        // 发起时的代次与传输要捕捉下来：回调回来时它们可能已经过时。被取代的 send 以取消
        // （-999）告终，而那个回调若还算数，就会把**刚建立的新连接**关掉、再排一次重连 ——
        // 新连接又被下一次重连掐回来，每 2 秒一转、永不恢复。
        let sentGeneration = generation
        let sentTask = task
        task?.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, let error else { return }
                guard Self.callbackApplies(generation: sentGeneration,
                                           current: self.generation,
                                           sameTask: self.task === sentTask) else {
                    Log.debug(Log.Module.session, "stale send failure on g\(sentGeneration) ignored (now g\(self.generation)): \(error)")
                    return
                }
                // 握手没完成或连接已死时 send 会在这里失败 —— 这是
                // 「发了开流内容却收不到任何帧」最常见的原因，必须留痕。
                Log.warn(Log.Module.session, "g\(sentGeneration) send failed: \(error)")
                self.closeTask()
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - 心跳与退避

    private func heartbeat(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        Task { [weak self] in
            while let self, self.generation == current, self.task === webSocketTask, self.following {
                try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                guard self.generation == current, self.task === webSocketTask else { return }
                // 证据**每拍消费一次**：这一拍收到过就归零，下一拍从零重新记。
                let heard = self.heardFromPeer
                self.heardFromPeer = false
                switch Self.livenessTick(established: !self.established.isEmpty,
                                         heardFromPeer: heard,
                                         missed: self.missedPongs,
                                         limit: self.maxMissedPongs) {
                case .probe(let missed):
                    self.missedPongs = missed
                    webSocketTask.sendPing { [weak self] error in
                        Task { @MainActor [weak self] in
                            // pong 回来了（completion 无错即 pong 已达）：对端活着。
                            // 这里只置证据旗，连失数由下一拍消费后清零。
                            if error == nil { self?.heardFromPeer = true }
                        }
                    }
                case .dead:
                    // 半开连接：对面不再回 pong。**必须留痕** —— 这条是「谁掐的」在客户端侧的
                    // 答案（网关侧的对应物见它自己的心跳）。
                    Log.warn(Log.Module.session, "g\(current) heartbeat: no pong in \(self.maxMissedPongs + 1) rounds — closing")
                    self.closeTask()
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    /// 一次心跳节拍的判定结果。
    enum Liveness: Equatable {
        /// 继续探活；`missed` 是本拍之后的连失数（未成流期恒为 0）。
        case probe(missed: Int)
        /// 对面已消失（半开连接）。
        case dead
    }

    /**
     一次心跳节拍的判定 —— 纯函数，与 `backoffDelayMs` 同类：这段编排里不碰 socket 就能断言的部分。

     规则两句话：**没成流的连接不判死；本拍收到过对端的东西就归零。**

     第一条的来由是「收到过任何一帧」这个前置项太弱：升级之后网关**先**发一条审批
     对账帧（它在打开帧之前），心跳会被它当场激活；紧接着打开帧的 1.25 MB 占住整条
     TCP（中继链路上要好几秒），网关的 pong 排在那一大帧**后面**，一拍也到不了 ⇒ 每代连接
     恰好活 6 秒（3 拍，`maxMissedPongs + 1`）就被自己判死。
     **「收到过东西」不等于「这条流已经建成」**，而心跳要判的是后者。

     第二条与网关侧同一条规则（`startHeartbeat`）：对端给我们发东西 ⇒ 它就是活的。一条正在收流的
     连接不该因为「这一拍没排到 pong」而被判死 —— pong 与它收到的帧抢同一条 TCP。

     没成流的那一段不是没人管：它归**就绪硬超时**（45s）—— 「没建起来」与「建起来又死了」是两件事。

     ⚠️ 已知未尽：**已成流之后**若单帧传输超过 6 秒（例如一条很大的工具结果），这条规则仍会判死 ——
     客户端拿不到「对面在忙」这个信息。根治要分片（把一帧拆成多帧，让控制帧能插进分片之间），
     代价是新增一套「窗口未到齐」的状态。现在不做：客户端可请求的会话里触发条件不可达，
     而分片会把一帧的语义拆成多帧、两头都要改。

     - Parameters:
       - established: 本代连接是否至少有一条流建成。
       - heardFromPeer: 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。
       - missed: 本拍之前累计的连失数。
       - limit: 允许的最大连失数。
     */
    static func livenessTick(established: Bool, heardFromPeer: Bool, missed: Int, limit: Int) -> Liveness {
        guard established, !heardFromPeer else { return .probe(missed: 0) }
        let next = missed + 1
        return next > limit ? .dead : .probe(missed: next)
    }

    /**
     迟到的回调该不该起作用 —— 代次与传输**双重相等**才算「本代当前的那条连接」。

     单独一个代次判据不够：同一代之内传输也可能已被替换（`connect` 里的先关后建）。判据松一格，
     一个被取代的 `send` 回调就会把新连接掐掉，而它自己又会再排一次重连。
     */
    static func callbackApplies(generation: Int, current: Int, sameTask: Bool) -> Bool {
        generation == current && sameTask
    }

    /**
     * 重连延迟的纯函数（`random` 注入）—— 曲线与抖动范围是这段编排里唯一**可断言**的行为：不碰
     * socket 就能验证。完整的「断线 → 退避 → 重连 → 代次递增」需要真网络，由真机测试覆盖。
     *
     * - Parameters:
     * - attempt: 第几次重连（从 1 起）。
     * - random: 抖动采样，`0..<1`。
     */
    static func backoffDelayMs(attempt: Int, random: Double) -> Int {
        // attempt 1 是第一次重连，指数从 2^0 起。
        let exponent = min(max(attempt, 1), 16) - 1
        let cap = min(baseBackoffMs * (1 << exponent), maxBackoffMs)
        return Int(Double(cap) * (0.5 + min(max(random, 0), 1) * 0.5))
    }

    /// 没有票时的那一步：去换，然后按结果安排下一步。
    ///
    /// 三种结果三种走向，**不能合并**：
    /// - 换到 → 立刻重连（跳过这次退避——它挡着的正是刚刚被解决的那个问题）
    /// - 等一等就好（网络不通 / 网关不在）→ 继续退避，状态没坏
    /// - 拿不到且不会自己好（未配对 / 关系被撤销）→ **停**。再试是纯空转：每 10 秒一次、
    ///   静默、永不收敛，而屏幕上什么都不会变。由界面去说「需要重新配对」。
    private func renewThenRetry() {
        guard following else { return }
        // 必须先离开 `.connecting`：这一代没有建出连接，而 `connect` 早在前几步就把
        // phase 置成了 `.connecting`。留着它有两个后果 —— 换到票之后 `reconnectNow`
        // 会以「正在握手」为由拒绝（于是永远连不上），而界面会一直显示「连接中…」。
        // `.idle` 在此刻是准确的：没有连接，也没有排定的重试（下面才决定要不要排）。
        phase = .idle
        guard let ticketRenewer else {
            // 没接换票器（预览 / 单测的裸实例）：退回退避，不假装自己会换。
            scheduleReconnect()
            return
        }
        Task { [weak self] in
            let outcome = await ticketRenewer()
            guard let self, self.following else { return }
            switch outcome {
            case .granted:
                Log.info(Log.Module.session, "ticket renewed — reconnecting now")
                self.reconnectNow()
            case .retryLater:
                self.scheduleReconnect()
            case .unavailable:
                Log.warn(Log.Module.session, "no ticket and none obtainable — stopping the follow loop")
                self.phase = .idle
            }
        }
    }

    /// 退避重连 —— 延迟由 `backoffDelayMs` 决定。
    private func scheduleReconnect() {
        guard following, openText != nil else { return }
        // 单飞：本拍取代尚未触发的那一拍。不取代的话两个定时器各起一条连接，后起的那条把先起
        // 的掐死、先起的失败回调再排一次，于是 attempt 编号跳着走、退避永远爬不到上限。
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1

        let delay = Self.backoffDelayMs(attempt: reconnectAttempt, random: Double.random(in: 0..<1))

        Log.info(Log.Module.session, "reconnect in \(delay)ms (attempt \(reconnectAttempt))")
        phase = .waiting(ms: delay)
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }
}
