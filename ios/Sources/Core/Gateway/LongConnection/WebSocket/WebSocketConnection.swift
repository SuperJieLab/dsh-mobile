/**
 * 一条 socket：握手、成帧循环、心跳、退避重连、代次、连接阶段。
 *
 * 存活范围是一条 socket；它不认识流 —— 收帧后把外壳与原始字节交给注入的闭包。
 * 判活只用两样证据：收到一条可解析的帧、我们 ping 的 pong 回来了。
 */
import Foundation

@MainActor
final class WebSocketConnection: Channel {

    /// 本网关提供流协议的精确路径。
    static let streamPath = "/rpc/stream"

    /// 单帧上限 —— 网关承诺打开帧不超过 4 MiB，这里取两倍；系统默认 1 MiB 会让大窗口打不开。
    static let maximumMessageSize = 8 * 1024 * 1024

    /// 心跳节拍，与网关的 `PING_INTERVAL_MS` 配套：单边改会让两端判死时机不一致。
    private static let pingInterval: TimeInterval = 2

    /// 判死窗口：多久没有任何证据就当这条连接死了。
    ///
    /// 60 秒必须长过最慢一帧的传输（4 MiB 在慢链路上约 34 秒），且显著大于流层的开流
    /// 超时（45 秒）；可写是为了让这条路径能被测试观测。
    var livenessWindow: TimeInterval = 60

    /// 这个窗口允许连失几拍（向上取整）；窗口不足两拍时抬到两拍。
    static func attemptLimit(for window: TimeInterval) -> Int {
        max(1, Int((window / pingInterval).rounded(.up)) - 1)
    }

    // MARK: - 注入

    /// 阶段变化（连接态指示器的数据源）。
    var onPhaseChange: ((ConnectionPhase) -> Void)?
    /// 取一张有效的访问凭证（升级请求带上它）。**没有就说明现在不该连。**
    var authorizationProvider: (() -> String?)?
    /// 换一张票。见 `renewThenRetry`：换到之后该重连、换不到该等还是该停，由本类决定。
    var ticketRenewer: (() async -> AccessTicket)?
    /// 不要连接了（App 收尾）。**谁订阅、听见了做什么，本层不知道。**
    var onStopped: (() -> Void)?
    /// 新一代连接开始了 —— 每次 `connect()` 一处。同上，订阅方自己决定反应。
    var onGenerationChange: (() -> Void)?
    /// 建连的传输与地址每次现取：组网激活后下一轮连接即走隧道，本类零改动。
    var sessionProvider: () -> URLSession = { .shared }
    var baseURLProvider: () -> URL? = { nil }

    // MARK: - 状态

    /// 连接阶段；通知挂在 setter 上，开流不改它。
    private(set) var phase: ConnectionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// 连接代次 —— 每次连接递增；回调带着发起时的代次，对不上就丢。
    private var generation = 0
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    /// 本代连接连续未回的 pong 数 —— 随代次清零。心跳那一拍累加，收到帧时清零。
    private var missedPongs = 0
    /// 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。心跳每拍消费一次。
    private(set) var heardFromPeer = false
    private var reconnectWorkItem: DispatchWorkItem?
    /// 是否要有一条连接 —— 只有它决定连不连，与「要开哪几条流」无关。
    private var active = false

    /// 已交给 socket 的帧文本（开流与取消两种）；对测试可读。
    private(set) var sentFrames: [String] = []

    /// 收到一帧（外壳 + 原始字节）。接线由外面做，本层不知道谁接。
    var onFrame: ((MuxServerEnvelope, Data) -> Void)?

    // MARK: - Channel

    var attempt: StreamAttempt? {
        guard let task else { return nil }
        return StreamAttempt(generation: generation, connection: task)
    }

    func send(_ text: String) {
        // 没有连接就什么都没发：不记账，也不假装发过。
        guard let sentTask = task else { return }
        sentFrames.append(text)
        // 发起时的代次与传输要捕捉：回调回来时它们可能已经过时，过时的回调会把新连接关掉。
        let sentGeneration = generation
        sentTask.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, let error else { return }
                guard Self.callbackApplies(generation: sentGeneration,
                                           current: self.generation,
                                           sameTask: self.task === sentTask) else {
                    Log.debug(Log.Module.session,
                              "stale send failure on g\(sentGeneration) ignored"
                              + " (now g\(self.generation)): \(error)")
                    return
                }
                // 握手没完成或连接已死时 send 会失败 —— 「发了开流内容却收不到帧」最常见的原因。
                Log.warn(Log.Module.session, "g\(sentGeneration) send failed: \(error)")
                self.closeTask()
                self.scheduleReconnect()
            }
        }
    }

    func ensureConnected() {
        guard active else { return }
        // 排着的那一拍退避取代掉：调用方说的是「现在就要」，而那一拍挡着的正是这件事。
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connect()
    }

    // MARK: - 生命周期

    /// 要一条连接（App 到了前台）。此刻可以一条流都没有。
    func activate() {
        guard !active else { return }
        active = true
        connect()
    }

    /// 不要连接了（App 收尾 / 测试清理）：关连接、取消一切定时器、清空流表。
    func deactivate() {
        active = false
        onStopped?()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTask()
        generation += 1 // 旧代次的一切回调就此作废
        phase = .idle
    }

    /// 立刻要一次重连（跳过退避）；已在握手或就绪的连接不受影响。
    /// - Parameter reason: 谁在要 —— 四个触发点，不写原因排障时看到一串一模一样的行。
    func reconnectNow(reason: String) {
        guard active else { return }
        guard phase != .ready, phase != .connecting else { return }
        // 「跳过退避」的前提是有东西可跳：没有地址时什么都不做，等组网就绪那一刻再来。
        // 这条不能并进上面的 guard —— 组网就绪时 `phase` 正好是 `.awaitingMesh`，那里必须放行。
        // 缺了它，本方法会先 cancel 掉排着的定时器再连不上，那一拍退避被吃掉且不再重排。
        guard baseURLProvider() != nil else {
            Log.info(Log.Module.session,
                     "reconnect now (\(reason)) — no endpoint yet, still waiting for mesh")
            return
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        Log.info(Log.Module.session, "reconnect now (\(reason)) — skipping backoff")
        connect()
    }

    // MARK: - 连接

    /// 起一次连接（新代次）。对内可见是为了断言「换代次后每条流都要用新编号重开」。
    func connect() {
        guard active else { return }
        // 无端点（组网未就绪）：不猜地址，也不进退避 —— 谁的条件谁等。
        // 就绪那一刻由 `reconnectNow` 叫醒；在这里退避会把「没有地址」记成网络失败。
        guard let endpoint = baseURLProvider() else {
            guard phase != .awaitingMesh else { return }
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            Log.info(Log.Module.session,
                     "connect skipped — waiting for mesh (no endpoint yet); not backing off")
            phase = .awaitingMesh
            return
        }
        // 不清零 reconnectAttempt：档位必须随失败次数爬升，否则退化成每秒一次。
        generation += 1
        let current = generation
        // 心跳判据随代次清零：上一代的连失数算到这一代头上会自锁，此后每代都在第一拍被判死。
        missedPongs = 0
        heardFromPeer = false
        phase = .connecting
        Log.perf(Log.Module.session, PerfRecord(
            seg: .dev, t: PerfRecord.nowMs(),
            fields: ["kind": .text("connect-init"), "gen": .number(Double(current))]
        ))

        // 上一代的连接先关掉：否则旧 socket 仍在泄漏，且系统的连接行为会互相干扰。
        if task != nil {
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

        // 升级请求带身份：与 HTTP 同一个头、同一张票。
        var upgradeRequest = URLRequest(url: components.url!)
        upgradeRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let webSocketTask = sessionProvider().webSocketTask(with: upgradeRequest)
        // 必须在 resume 之前设：超过上限的帧会让 receive 直接以 POSIX 40 失败。
        webSocketTask.maximumMessageSize = Self.maximumMessageSize
        task = webSocketTask
        // 只报代次与地址：流标签是流层的词汇，本层不解释它（流层自己重开时按流记一行）。
        Log.info(Log.Module.session, "connect g\(current) → \(components.url!)")
        webSocketTask.resume()

        // 换代次之后谁要发帧、发什么，由订阅方自己决定。
        onGenerationChange?()

        // 开流超时不在这里起 —— 它挂在每一次开流尝试上（见 `StreamMux.armOpenTimeout`）。
        receiveLoop(on: webSocketTask, generation: current)
        heartbeat(on: webSocketTask, generation: current)
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
                    // 连接死了：清场走退避重连。打印具体原因 —— ATS / 路由器隔离各有错误码。
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

    /// 一帧到了：先记「对面还活着」的证据，再按编号归流。
    /// 对内可见是为了断言这个顺序 —— 它关乎健康连接会不会被自己的心跳判死。
    func handleMessage(_ message: URLSessionWebSocketTask.Message, generation current: Int) {
        // 收到任何一帧都是「对端还活着」的证据，由心跳那一拍消费 —— 系统不暴露字节进度。
        heardFromPeer = true
        guard case .string(let text) = message else {
            Log.debug(Log.Module.session, "g\(current) non-text frame ignored")
            return
        }
        let rawData = Data(text.utf8)
        guard let frame = try? JSONDecoder().decode(MuxServerEnvelope.self, from: rawData) else {
            Log.warn(Log.Module.session,
                     "g\(current) unparsable frame (first 120 chars): \(text.prefix(120))")
            return // 解不了的帧不是消息，忽略
        }
        Log.debug(Log.Module.session, "g\(current) frame: \(frame.type)")

        // 一条可解析的帧 = 这一代真的通了：退避归零、连失清零、阶段就绪。就绪与存活是同一个信号。
        reconnectAttempt = 0
        missedPongs = 0
        phase = .ready

        // 每个帧都有编号（协议如此），整帧交给接帧的那一侧 —— 本层不判编号的含义。
        onFrame?(frame, rawData)
    }

    // MARK: - 心跳与退避

    private func heartbeat(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        Task { [weak self] in
            while let self, self.generation == current, self.task === webSocketTask, self.active {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard self.generation == current, self.task === webSocketTask else { return }
                // 证据每拍消费一次、连失数在 `livenessStep` 里累加 —— 这里只负责按判定动作。
                switch self.livenessStep() {
                case .probe:
                    webSocketTask.sendPing { [weak self] error in
                        Task { @MainActor [weak self] in
                            // pong 回来了（completion 无错即 pong 已达）：对端活着。
                            if error == nil { self?.heardFromPeer = true }
                        }
                    }
                case .dead:
                    // 半死连接：对面不再回 pong。必须留痕 —— 「谁掐的」在客户端侧的答案。
                    Log.warn(Log.Module.session,
                             "g\(current) heartbeat: silent for \(Int(self.livenessWindow))s"
                             + " — closing")
                    self.closeTask()
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    /// 一次心跳节拍的判定结果。
    enum Liveness: Equatable {
        /// 继续探活；`missed` 是本拍之后的连失数。
        case probe(missed: Int)
        /// 对面已消失（半死连接）。
        case dead
    }

    /// 一拍：消费本拍证据、算出判定。心跳只调这一个方法，`livenessWindow` 也只在这里被读 ——
    /// 拆成「纯函数 + 适配器」时心跳那一跳仍可绕开它，被断言的就不是这件事。
    func livenessStep() -> Liveness {
        let heard = heardFromPeer
        heardFromPeer = false
        let verdict = Self.livenessTick(window: livenessWindow, heardFromPeer: heard,
                                        missed: missedPongs)
        if case .probe(let missed) = verdict { missedPongs = missed }
        return verdict
    }

    /**
     一次心跳节拍的判定 —— 纯函数：这段编排里不碰 socket 就能断言的部分。

     规则一句话：**本拍收到过对端的东西就归零；否则连失累加，越过窗口那一拍判死。**

     「传大帧时误杀」由**窗口本身够长**兜住（默认 60 秒，见 `livenessWindow`）：
     大帧传输期间 `receive` 与 pong 都排在它后面，一拍也回不来，所以这里的判据不是
     「先别判」而是「等不到就等久一点」。

     空闲段（停在会话列表、一条流都没有）同样要判：半死连接在空闲段最常见，
     放过它就等于永远发现不了 —— 于是这个函数不区分有没有流。

     ⚠️ 已知未尽：**已成流之后**若单帧传输超过整个窗口（例如一条很大的工具结果），
     这条规则仍会判死 —— 客户端拿不到「对面在忙」这个信息。

     - Parameters:
       - window: 判死窗口；允许连失 `window ÷ 节拍 - 1` 拍。
       - heardFromPeer: 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。
       - missed: 本拍之前累计的连失数。
     */
    static func livenessTick(window: TimeInterval, heardFromPeer: Bool, missed: Int) -> Liveness {
        guard !heardFromPeer else { return .probe(missed: 0) }
        let next = missed + 1
        return next > attemptLimit(for: window) ? .dead : .probe(missed: next)
    }

    /**
     迟到的回调该不该起作用 —— 代次与传输**双重相等**才算「本代当前的那条连接」。

     单独一个代次判据不够：同一代之内传输也可能已被替换（`connect` 里的先关后建）。
     判据松一格，一个被取代的 `send` 回调就会把新连接掐掉，而它自己又会再排一次重连。
     */
    static func callbackApplies(generation: Int, current: Int, sameTask: Bool) -> Bool {
        generation == current && sameTask
    }

    /// 没有票时的那一步：去换，再按结果安排下一步。三种结果不能合并 —— 换到就立刻重连
    /// （跳过退避），等一等就好就继续退避，拿不到且不会自己好就停（再试是空转）。
    private func renewThenRetry() {
        guard active else { return }
        // 先离开 `.connecting`：留着它，换到票之后 `reconnectNow` 会以「正在握手」为由拒绝。
        phase = .idle
        guard let ticketRenewer else {
            // 没接换票器（预览 / 单测的裸实例）：退回退避，不假装自己会换。
            scheduleReconnect()
            return
        }
        Task { [weak self] in
            let outcome = await ticketRenewer()
            guard let self, self.active else { return }
            switch outcome {
            case .granted:
                Log.info(Log.Module.session, "ticket renewed — reconnecting now")
                self.reconnectNow(reason: "ticket renewed")
            case .retryLater:
                // 留痕：「没票、等一等」与「没端点、等组网」在日志里必须分得开。
                Log.info(Log.Module.session, "no ticket yet (retry later) — backing off")
                self.scheduleReconnect()
            case .unavailable:
                Log.warn(Log.Module.session,
                         "no ticket and none obtainable — stopping the follow loop")
                self.phase = .idle
            }
        }
    }

    /// 退避重连 —— 延迟由 `Backoff` 决定。
    private func scheduleReconnect() {
        guard active else { return }
        // 单飞：本拍取代尚未触发的那一拍，否则两个定时器各起一条连接、退避爬不到上限。
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1

        let delay = Backoff.delayMs(
            attempt: reconnectAttempt, random: Double.random(in: 0..<1)
        )

        Log.info(Log.Module.session, "reconnect in \(delay)ms (attempt \(reconnectAttempt))")
        phase = .waiting(ms: delay)
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }
}
