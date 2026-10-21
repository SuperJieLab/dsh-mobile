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
 * 不解释任何帧：解析成 JSON 原样递回调，形状与语义在 `SessionSync`。协议名与端口全从
 * `GatewayClient.baseURL` 推导 —— 全 App 只有一个要改的地址。
 */@MainActor
final class FollowClient: NSObject {

    /// 连接阶段。`waiting` 携带下一次重连前的毫秒数，界面可以如实显示。
    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case waiting(ms: Int)
    }
    // MARK: - 回调（由编排层注入；全部在主线程）

    /// opening 帧：typed 直解，外壳与事件数组一次解码齐备。
    var onOpening: ((OpeningFrame) -> Void)?
    /// 一条持久事件（DSH 事件对象原样）。
    var onEvent: ((SessionEvent) -> Void)?
    /// 一条未定稿帧（start/chunk/end，原样）。
    var onTransient: ((JSONValue) -> Void)?
    /// 一条连接级审批帧（`{kind:'request'|'cancel', ...}` 原样）。
    var onApproval: ((JSONValue) -> Void)?
    /// 一份上下文占用读数。两个来源、同一个形状：opening 里的基线，以及随后的 `usage` 帧。
    /// 缺席的含义与「空」不同 —— 字段**不在** = 服务端读不出（保留手里那份），字段在而 `usage` 为空
    /// = 这个水位上确实没有可显示的东西（清空）。
    var onUsage: ((UsageSnapshot) -> Void)?
    /// 一条 error 帧 —— 流通道里的协议内拒绝。
    var onRefused: ((GatewayFailure) -> Void)?
    /// 连接阶段变化（连接态指示器的数据源）。
    var onPhaseChange: ((Phase) -> Void)?
    /// 取一张有效的访问凭证 —— upgrade 请求带上它。**没有就说明现在不该连**：
    /// 见 `connect` 里对空票的处理。
    var authorizationProvider: (() -> String?)?
    /// 手上没有票时叫一声 —— 上层去换一张，换到了再 `reconnectNow()` 提速。
    ///
    /// 为什么必须有人管这件事：退避重连这条路上没有别的东西会去换票（`start` 与
    /// `reconnectNow` 的前置都只在各自入口跑一次）。票过期后若照旧裸连，每一轮退避都是
    /// 一次注定被拒的握手，而且**永不收敛** —— 服务端看不到票，我们也永远拿不到新的，
    /// 直到有人回前台或重新进屏。那表现就是静默断流，不是慢一下。
    var onMissingTicket: (() -> Void)?
    /// 建连的传输与地址每次现取：store 激活后下一轮连接即走隧道，本类零改动。
    /// 返回 nil = 端点不存在（未激活）——不猜地址，connect 据此进退避等待。
    var sessionProvider: () -> URLSession = { .shared }
    var baseURLProvider: () -> URL? = { nil }

    // MARK: - 状态

    /// 连接阶段 —— 对外由 `onPhaseChange` 转发（`SessionSync.connectionPhase`）。
    /// 通知挂在 setter 上：
    /// `connect`、`openFollowStream`、收到 opening、退避等待、`stop` 五处都会改它，
    /// 手写必定漏接一处。
    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// 连接代次 —— 每次连接递增；回调带着发起时的代次，对不上就丢。
    private var generation = 0
    private var sessionId: String?
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
    /// opening 就当这次尝试没成。
    ///
    /// 取值 45s **不是**照抄上游的 15s（那是给快链路的）。我们的 opening 是这条流里**最大的
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
    private static let streamId = 1
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

    /// 开始订阅一个会话。重复调用同一会话是幂等的；换会话会先停旧的。
    func start(sessionId newSessionId: String) {
        if following, sessionId == newSessionId { return }
        stop()
        following = true
        sessionId = newSessionId
        connect()
    }

    /// 停止订阅：关连接、取消一切定时器。之后不再重连。
    func stop() {
        following = false
        sessionId = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTask()
        generation += 1 // 旧代次的一切回调就此作废
        phase = .idle
    }

    /// 重开当前流：用于未定稿断号 —— 现有连接还活着，但这一段的基线已经丢了。
    /// 重新 open（同一条连接上）拿新 opening；连接本身不重建。
    func reopenStream() {
        guard following, let sessionId else { return }
        openFollowStream(sessionId: sessionId)
    }

    /// 回前台立即触发一次重连 —— 上游「恢复立即试」（online 事件 → 重连控制器）的复现。
    /// 退避窗口里的等待被跳过；已在握手或就绪的连接不受影响，不叠加并发连接。
    func reconnectNow() {
        guard following, sessionId != nil else { return }
        guard phase != .ready, phase != .connecting else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        Log.info(Log.Module.session, "foreground — reconnecting immediately (skipping backoff)")
        connect()
    }

    // MARK: - 连接

    private func connect() {
        guard following, sessionId != nil else { return }
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
        phase = .connecting
        // 连接发起时刻：与 opening 记录配对后可以算追平延迟（按代次对齐）。
        Log.perf(Log.Module.session, PerfRecord(
            seg: .dev, t: PerfRecord.nowMs(), sessionId: sessionId,
            fields: ["kind": .text("connect-init"), "gen": .number(Double(current))]
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

        // 没有票**不裸连**：这一发必定被 401 拒，而且在退避循环里票不会自己长出来 ——
        // 一旦这样起步，此后每一轮都是同一个失败。改为「叫一声去换票 + 继续退避」：
        // 换到之后上层调 `reconnectNow()` 跳过剩下的等待，换不到就下一轮再试。
        guard let access = authorizationProvider?() else {
            Log.info(Log.Module.session, "connect g\(current) skipped — no access ticket; asking for a new one")
            onMissingTicket?()
            scheduleReconnect()
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
        // 带上会话 id：`g2` 在两个实例（进出详情各一个）里会重号，
        // 只有会话 id 能区分「谁的第 2 代」。
        Log.info(Log.Module.session, "connect g\(current) [\(sessionId ?? "-")] → \(components.url!)")
        webSocketTask.resume()

        // 握手由系统完成，open 帧立即发出（未就绪的连接会替我们排队）——
        // 服务端等的就是它：没有 open，永远不会有 opening。
        if let sessionId {
            Log.debug(Log.Module.session, "g\(current) sending open for \(sessionId)")
            openFollowStream(sessionId: sessionId)
        }

        // 就绪硬超时不在这里起 —— 它挂在 `openFollowStream` 上，于是「每一次开流尝试」都带时限
        //（首连与重开同路），见 `armReadyTimeout`。
        receiveLoop(on: webSocketTask, generation: current)
        heartbeat(on: webSocketTask, generation: current)
    }

    /// 在当前连接上发一条 open 帧，开始（或重建）订阅流。
    private func openFollowStream(sessionId sessionIdToFollow: String) {
        phase = .connecting
        let open: [String: JSONValue] = [
            "type": .string("open"),
            "streamId": .number(Double(Self.streamId)),
            "payload": .object([
                "op": .string("follow"),
                "sessionId": .string(sessionIdToFollow),
            ]),
        ]
        send(open)
        // 每一次开流尝试都在这里带时限 —— 首连与重开（`end` 帧、`reopenStream`）走的是同一个入口。
        // 只在 `connect` 里 arm 会漏掉重开：那时「等不到 opening」就没有任何看门人（心跳只管已成流
        // 的连接，见 `livenessTick`）。
        armReadyTimeout()
    }

    /// 就绪硬超时：从**这次开流尝试**起算，多久没等到 opening 就当它没成。
    ///
    /// ⚠️ `budget` 是**秒**，必须乘 10⁹ 转成纳秒。把秒数直接当纳秒传进去，超时会在
    /// 微秒级就到点 —— 每次连接都立即被判失败，open 帧被 cancel 成 -999，
    /// 于是永远收不到 opening，而日志里只看到无穷无尽的「重连」。
    private func armReadyTimeout() {
        guard let webSocketTask = task else { return }
        let current = generation
        let budget = Self.readyTimeout
        let sessionIdForLog = sessionId ?? "-"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard let self, self.generation == current, self.task === webSocketTask, self.phase != .ready else { return }
            // 这一行是「这次连接为什么没成」的第一现场：45 秒还没等到 opening，通常意味着
            // 慢链路正传一大帧（1.25 MB 在 125 KB/s 上要传约 10 秒），或者对面根本没在
            // 服务这个会话。
            Log.warn(Log.Module.session, "g\(current) [\(sessionIdForLog)] ready timeout (\(Int(budget))s) — closing and retrying")
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

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, generation current: Int) {
        // 收到任何一帧都是「对端还活着」的证据 —— 由心跳那一拍消费（见 `livenessTick`）。
        // ⚠️ 它**不**等于「这条流已建成」：升级后先到的 approval 对账帧也算「收到过东西」，
        // 而那时 opening 的一大帧可能还在路上 —— 把它当成就绪，心跳会立刻激活、
        // 再在几拍之后把一条正在正常传输的连接判死。
        heardFromPeer = true
        guard case .string(let text) = message else {
            Log.debug(Log.Module.session, "g\(current) non-text frame ignored")
            return
        }
        let rawData = Data(text.utf8)
        guard let frame = try? JSONDecoder().decode(MuxFrame.self, from: rawData) else {
            Log.warn(Log.Module.session, "g\(current) unparsable frame (first 120 chars): \(text.prefix(120))")
            return // 解不了的帧不是消息，忽略
        }
        Log.debug(Log.Module.session, "g\(current) frame: \(frame.type)")

        switch frame.type {
        case "item":
            guard let payload = frame.payload else { return }
            if payload["sessionId"] != nil && payload["cursor"] != nil && payload["events"] != nil {
                // opening：就绪的标志。typed 直解一次 —— 坏事件由
                // FailableDecodable 单条跳过，其余照常显示。
                reconnectAttempt = 0
                missedPongs = 0
                guard let opening = OpeningFrame.decode(rawData) else {
                    Log.warn(Log.Module.session, "g\(current) opening unparsable (first 120 chars): \(text.prefix(120))")
                    return
                }
                phase = .ready
                // opening 的到达时刻即「应用完成」时刻：`onOpening` 同步跑完整段折叠，
                // 批出的全量重算属渲染路径，不计入这一段。
                let openingRecv = PerfRecord.nowMs()
                onOpening?(opening)
                Log.perf(Log.Module.session, PerfRecord(
                    seg: .dev, t: PerfRecord.nowMs(), sessionId: opening.sessionId, seq: opening.cursor,
                    fields: [
                        "kind": .text("opening"),
                        "gen": .number(Double(current)),
                        "devRecv": .number(openingRecv),
                        "devApply": .number(PerfRecord.nowMs()),
                        "bytes": .number(Double(rawData.count)),
                    ]
                ))
                // 占用基线随 opening 一同到达（服务端读不出投影时不带这个字段，
                // 那与「这个水位上没有值」是两件事，所以只在字段在时才上报）。
                if let baseline = opening.occupancy { onUsage?(baseline) }
            } else if payload["type"]?.string == "assistant-stream" {
                onTransient?(payload["frame"] ?? .null)
            } else if payload["type"]?.string != nil, payload["seq"] != nil {
                // 事件帧：payload 本体就是 SessionEvent —— 直解一次；解不出如实丢弃，
                // 不重试、不猜。
                guard let envelope = try? JSONDecoder().decode(FrameWithEvent.self, from: rawData),
                      let event = envelope.payload?.value else { return }
                // 帧的到达即「应用完成」：`onEvent` 同步跑完镜像合并、状态机吸收与
                // 刷新闸标记；批出的全量重算属渲染路径，不计入这一段。
                let devRecv = PerfRecord.nowMs()
                onEvent?(event)
                Log.perf(Log.Module.session, PerfRecord(
                    seg: .dev, t: PerfRecord.nowMs(), sessionId: sessionId, seq: event.seq,
                    fields: [
                        "kind": .text("event"),
                        "gen": .number(Double(current)),
                        "devRecv": .number(devRecv),
                        "devApply": .number(PerfRecord.nowMs()),
                        "bytes": .number(Double(rawData.count)),
                    ]
                ))
            }

        case "error":
            let failure = GatewayFailure(
                code: frame.payload?["code"]?.string ?? GatewayErrorCode.internalError.rawValue,
                message: frame.payload?["message"]?.string ?? ""
            )
            onRefused?(failure)
            // 会话级终态重连无意义；其余退避重连。
            if Self.isTerminal(code: failure.code) {
                stop()
            } else {
                closeTask()
                scheduleReconnect()
            }

        case "end":
            // 流被服务端正常收尾 —— 重开一个（例如服务端主动收尾的会话）。
            if let sessionId { openFollowStream(sessionId: sessionId) }

        case "approval":
            // 连接级审批推送（无 streamId）：连接活着就有，与订阅流无关。
            if let payload = frame.payload { onApproval?(payload) }

        case "usage":
            // 占用读数。与 `approval` 不同，它**带 `streamId`** —— 属于本流
            // 打开的那个会话，所以核一次 `sessionId`（帧串流时不能画别人的占用）。
            guard let payload = frame.payload, let sessionId,
                  payload["sessionId"]?.string == sessionId else { return }
            guard let envelope = try? JSONDecoder().decode(FrameWithUsage.self, from: rawData),
                  let snapshot = envelope.payload?.value else { return }
            onUsage?(snapshot)

        default:
            break
        }
    }

    // MARK: - 发

    private func send(_ json: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(json),
              let text = String(data: data, encoding: .utf8) else { return }
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
                // 「发了 open 却收不到任何帧」最常见的原因，必须留痕。
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
                switch Self.livenessTick(established: self.phase == .ready,
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
                    // 答案（网关侧的对应物见 `remote/ws.ts` 的心跳）。
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

     第一条的来由是「收到过任何一帧」这个前置项太弱：升级之后网关**先**发一条 approval
     对账帧（它在 opening 之前），心跳会被它当场激活；紧接着 opening 的 1.25 MB 占住整条
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
       - established: 本代连接是否已成流（opening 已应用）。
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
     * 重连有没有意义 —— `true` 表示这是会话级终态：重连只会得到同一个结果。
     *
     * `window-too-large` 属于这一类：那个窗口不会因为重连而变小，
     * 反复重连只会把一次确定的拒绝变成一串无用的尝试。**未知码按可重试处理** ——
     * 白名单之外的码不该让会话卡死。
     */
    static func isTerminal(code: String) -> Bool {
        code == GatewayErrorCode.unknownSession.rawValue
            || code == GatewayErrorCode.unreadableSession.rawValue
            || code == GatewayErrorCode.windowTooLarge.rawValue
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

    /// 退避重连 —— 延迟由 `backoffDelayMs` 决定。
    private func scheduleReconnect() {
        guard following, sessionId != nil else { return }
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

// MARK: - 帧与载荷的解析

/// mux 帧的外壳：`{type, streamId, payload?}`（服务端只发 item / end / error）。
private struct MuxFrame: Decodable {
    let type: String
    let payload: JSONValue?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey { case type, streamId, payload }
}

/// 事件帧的 typed 信封：payload 本体就是 SessionEvent。
private struct FrameWithEvent: Decodable {
    let payload: FailableDecodable<SessionEvent>?
}

/// usage 帧的 typed 信封：payload 本体就是 UsageSnapshot。
private struct FrameWithUsage: Decodable {
    let payload: FailableDecodable<UsageSnapshot>?
}
