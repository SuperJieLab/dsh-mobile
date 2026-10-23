/**
 * 一条 socket：握手、成帧循环、心跳、退避重连、代次、连接阶段。
 *
 * 存活范围是一条 socket。它自己决定「连不连 / 等多久 / 判不判死 / 迟到的回调算不算数」，
 * 失败经接口或阶段迁移交出；它**不认识流** —— 不造编号、不建表、不按编号分支，
 * 收帧之后整帧交给 `StreamMux`。反过来流层要发文本、要连接、要放弃，都经它实现的
 * `StreamPort` 进来。
 *
 * 它也不定义「就绪」：系统没有「已连接」这个回调，唯一的信号是「收到东西」，
 * 而收到东西不等于某条流建成（网关先发对账帧、打开帧的大帧还在路上）。所以 `.ready`
 * 只由流层报「某条流建成了」触发。
 */
import Foundation

@MainActor
final class StreamTransport: StreamPort, UnscopedFrameFeed {

    /// 本网关提供流协议的精确路径。
    static let streamPath = "/rpc/stream"

    /// 单帧接收上限 —— 网关承诺打开帧不超过 4 MiB，这里取它的两倍：覆盖任何非窗口帧，
    /// 并留出两端读数差异的余量。系统默认只有 1 MiB，那正是「某个会话打不开」的成因。
    static let maximumMessageSize = 8 * 1024 * 1024

    /// 心跳节拍，与网关的 `PING_INTERVAL_MS` 配套：单边改会让两端判死时机不一致。
    private static let pingInterval: TimeInterval = 2
    /// 允许连失几拍。第 `limit + 1` 拍仍没有证据即判死。
    private static let maxMissedPongs = 2

    // MARK: - 注入

    /// 阶段变化（连接态指示器的数据源）。
    var onPhaseChange: ((StreamPhase) -> Void)?
    /// 无编号帧的收货人，与连接同寿。
    var unscopedSink: (any UnscopedFrameSink)?
    /// 取一张有效的访问凭证（升级请求带上它）。**没有就说明现在不该连。**
    var authorizationProvider: (() -> String?)?
    /// 换一张票。见 `renewThenRetry`：换到之后该重连、换不到该等还是该停，由本类决定。
    var ticketRenewer: (() async -> AccessTicket)?
    /// 建连的传输与地址每次现取：组网激活后下一轮连接即走隧道，本类零改动。
    var sessionProvider: () -> URLSession = { .shared }
    var baseURLProvider: () -> URL? = { nil }

    // MARK: - 状态

    /// 连接阶段。通知挂在 setter 上：`connect`、收到开口帧、退避等待、`deactivate`
    /// 四处都会改它，手写必定漏接一处。**开流不改它** —— 在已就绪的连接上开第二条流，
    /// 屏幕不该闪「连接中」。
    private(set) var phase: StreamPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// 连接代次 —— 每次连接递增；回调带着发起时的代次，对不上就丢。
    private var generation = 0
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    /// 本代连接连续未回的 pong 数 —— 随代次清零。唯一写者是心跳那一拍。
    private var missedPongs = 0
    /// 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。心跳每拍消费一次。
    private(set) var heardFromPeer = false
    private var reconnectWorkItem: DispatchWorkItem?
    /// 是否要有一条连接 —— 只有它决定连不连，与「要开哪几条流」无关。
    private var active = false

    /// 已交给 socket 的帧文本（只有开流与取消两种，都是事务、量小且可数）。
    /// 对测试可读：判据要问「注销时到底发没发帧、发的是哪个编号」。
    private(set) var sentFrames: [String] = []

    /// 流表。传输层是它唯一的持有者，本层只经四个动作与它往来（见文件头）。
    ///
    /// 对内可见而不是 `private`：判据要能问「这一帧归到了哪条流」，
    /// 而那件事只有流表回答得了；它不该为了断言敞开一张表。
    let mux: StreamMux

    init(mux: StreamMux? = nil) {
        // `nil` 而不是默认表达式：跨 actor 的默认值求值不合法。可注入是为了这一跳能被断言。
        let mux = mux ?? StreamMux()
        self.mux = mux
        mux.attach(port: self)
    }

    // MARK: - StreamPort

    var attempt: StreamAttempt? {
        guard let task else { return nil }
        return StreamAttempt(generation: generation, connection: task)
    }

    func send(_ text: String) {
        // 没有连接就什么都没发：不记账，也不假装发过。
        guard let sentTask = task else { return }
        sentFrames.append(text)
        // 发起时的代次与传输要捕捉下来：回调回来时它们可能已经过时。被取代的 send 以取消
        // 告终，而那个回调若还算数，就会把刚建立的新连接关掉、再排一次重连 ——
        // 新连接又被下一次重连掐回来，每 2 秒一转、永不恢复。
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
                // 握手没完成或连接已死时 send 会在这里失败 —— 这是
                // 「发了开流内容却收不到任何帧」最常见的原因，必须留痕。
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

    func abandon(_ reason: AbandonReason, attempt: StreamAttempt) {
        // 不是这一次尝试就没这条连接的事了（已经换过代次或换了传输）。
        guard self.attempt == attempt else { return }
        switch reason {
        case .streamNotReady:
            closeTask()
            scheduleReconnect()
        }
    }

    func didEstablish() {
        reconnectAttempt = 0
        missedPongs = 0
        phase = .ready
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
        mux.closeAll()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTask()
        generation += 1 // 旧代次的一切回调就此作废
        phase = .idle
    }

    /// 回前台立即触发一次重连（跳过退避）。已在握手或就绪的连接不受影响，不叠加。
    func reconnectNow() {
        guard active else { return }
        guard phase != .ready, phase != .connecting else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        Log.info(Log.Module.session, "foreground — reconnecting immediately (skipping backoff)")
        connect()
    }

    // MARK: - 连接

    /// 起一次连接（新代次）。
    ///
    /// 对内可见（不 `private`）与 `handleMessage` / `livenessTick` 同理：这里有一条
    /// 只有在此处才断言得到的契约 —— 换代次之后每条登记着的流都要用自己的新编号重开。
    func connect() {
        guard active else { return }
        // 无端点（组网未激活）：不猜地址，也不动代次与阶段的连接语义，直接进退避 ——
        // 激活后下一轮自动连上。
        guard let endpoint = baseURLProvider() else {
            scheduleReconnect()
            return
        }
        // 不在这里清零 reconnectAttempt —— 退避档位必须随失败次数爬升，
        // 否则握手持续失败时会退化成每秒一次的疯狂循环。
        generation += 1
        let current = generation
        // 心跳的判据随代次清零：连失数与「活过」的证据都不继承。上一代的欠账算到这一代
        // 头上会自锁 —— 一次没建成的连接把连失数攒到上限之后，此后每一代都在第一个心跳
        // 节拍就被判死，2 秒一转、永不恢复。
        missedPongs = 0
        heardFromPeer = false
        phase = .connecting
        Log.perf(Log.Module.session, PerfRecord(
            seg: .dev, t: PerfRecord.nowMs(),
            fields: ["kind": .text("connect-init"), "gen": .number(Double(current)),
                     "who": .text(labelsText)]
        ))

        // 上一代次的连接必须先关掉：不关的话旧 socket 的 receive / heartbeat 还在
        //（回调虽被代次拦住，连接本身泄漏），且系统的连接行为会互相干扰。
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
        // 带上标识：`g2` 在两个实例里会重号，只有它加上标签能区分「谁的第 2 代」。
        Log.info(Log.Module.session,
                 "connect g\(current) [\(labelsText)] → \(components.url!)")
        webSocketTask.resume()

        // 握手由系统完成，开流内容立即发出（未就绪的连接会替我们排队）——
        // 服务端等的就是它：没有它，永远不会有打开帧。没有流时这些什么都不发。
        mux.reopenAll()

        // 就绪硬超时不在这里起 —— 它挂在每一次开流尝试上（见 `StreamMux.armReadyTimeout`）。
        receiveLoop(on: webSocketTask, generation: current)
        heartbeat(on: webSocketTask, generation: current)
    }

    /// 表里各条流的标签（按登记序、逗号分隔），只进日志 —— 本层不解释它们。
    private var labelsText: String {
        let labels = mux.streamLabels
        return labels.isEmpty ? "-" : labels.joined(separator: ",")
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

    /// 一帧到了：先记「对面还活着」的证据，再按编号归流。
    ///
    /// 对内可见（不 `private`）与 `connect` 同理：这里有一条只能在此处断言的**顺序** ——
    /// 「收到任何东西」先于「按编号归流」。它关乎一条健康连接会不会被自己的心跳判死。
    func handleMessage(_ message: URLSessionWebSocketTask.Message, generation current: Int) {
        // 收到任何一帧都是「对端还活着」的证据 —— 由心跳那一拍消费。
        // ⚠️ 它**不**等于「这条流已建成」：升级后先到的任何一帧都算「收到过东西」，
        // 而那时打开帧的一大帧可能还在路上 —— 把它当成就绪，心跳会立刻激活、
        // 再在几拍之后把一条正在正常传输的连接判死。
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

        // 没有编号的帧不属于任何一条流，交给连接级收货人；有编号的整帧交给流表。
        // 本层不判编号的含义，只判它在不在。
        if frame.streamId == nil {
            unscopedSink?.accept(frame)
        } else {
            mux.receive(frame, raw: rawData)
        }
    }

    // MARK: - 心跳与退避

    private func heartbeat(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        Task { [weak self] in
            while let self, self.generation == current, self.task === webSocketTask, self.active {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard self.generation == current, self.task === webSocketTask else { return }
                // 证据**每拍消费一次**：这一拍收到过就归零，下一拍从零重新记。
                let heard = self.heardFromPeer
                self.heardFromPeer = false
                switch Self.livenessTick(awaitingOpening: self.mux.hasPendingOpening,
                                         heardFromPeer: heard,
                                         missed: self.missedPongs,
                                         limit: Self.maxMissedPongs) {
                case .probe(let missed):
                    self.missedPongs = missed
                    webSocketTask.sendPing { [weak self] error in
                        Task { @MainActor [weak self] in
                            // pong 回来了（completion 无错即 pong 已达）：对端活着。
                            if error == nil { self?.heardFromPeer = true }
                        }
                    }
                case .dead:
                    // 半死连接：对面不再回 pong。必须留痕 —— 「谁掐的」在客户端侧的答案。
                    Log.warn(Log.Module.session,
                             "g\(current) heartbeat: no pong in \(Self.maxMissedPongs + 1)"
                             + " rounds — closing")
                    self.closeTask()
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    /// 一次心跳节拍的判定结果。
    enum Liveness: Equatable {
        /// 继续探活；`missed` 是本拍之后的连失数（有流在等打开帧时恒为 0）。
        case probe(missed: Int)
        /// 对面已消失（半死连接）。
        case dead
    }

    /**
     一次心跳节拍的判定 —— 纯函数：这段编排里不碰 socket 就能断言的部分。

     规则两句话：**有流在等打开帧时不判死；本拍收到过对端的东西就归零。**

     第一条的来由是「收到过任何一帧」这个前置项太弱：升级之后网关**先**发一条审批对账帧
     （它在打开帧之前），心跳会被它当场激活；紧接着打开帧的一大帧占住整条 TCP
     （中继链路上要好几秒），网关的 pong 排在那一大帧**后面**，一拍也到不了 ⇒ 每代连接
     恰好活 6 秒就被自己判死。**「收到过东西」不等于「这条流已经建成」。**

     为什么门槛是「**正在**等打开帧」而不是「还没建成」：连接常驻之后，大量时间根本没有
     流（停在会话列表）。照旧一律不判死，那一段的半死连接就永远发现不了 —— 表现是
     「回到会话详情没有内容，也不重连」。所以空闲段必须判，只有「正在等打开帧」这一段让路。

     没有流在等打开帧的那一段不是没人管：正在等的那段归**就绪硬超时**（45s）——
     「没建起来」与「建起来又死了」是两件事。

     ⚠️ 已知未尽：**已成流之后**若单帧传输超过 6 秒（例如一条很大的工具结果），这条规则
     仍会判死 —— 客户端拿不到「对面在忙」这个信息。根治要分片（把一帧拆成多帧，让控制帧
     能插进分片之间），代价是新增一套「窗口未到齐」的状态。

     - Parameters:
       - awaitingOpening: 本代是否有一条流已发出 open、还没收到开口帧。
       - heardFromPeer: 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。
       - missed: 本拍之前累计的连失数。
       - limit: 允许的最大连失数。
     */
    static func livenessTick(awaitingOpening: Bool, heardFromPeer: Bool,
                             missed: Int, limit: Int) -> Liveness {
        guard !awaitingOpening, !heardFromPeer else { return .probe(missed: 0) }
        let next = missed + 1
        return next > limit ? .dead : .probe(missed: next)
    }

    /**
     迟到的回调该不该起作用 —— 代次与传输**双重相等**才算「本代当前的那条连接」。

     单独一个代次判据不够：同一代之内传输也可能已被替换（`connect` 里的先关后建）。
     判据松一格，一个被取代的 `send` 回调就会把新连接掐掉，而它自己又会再排一次重连。
     */
    static func callbackApplies(generation: Int, current: Int, sameTask: Bool) -> Bool {
        generation == current && sameTask
    }

    /// 没有票时的那一步：去换，然后按结果安排下一步。
    ///
    /// 三种结果三种走向，**不能合并**：
    /// - 换到 → 立刻重连（跳过这次退避 —— 它挡着的正是刚刚被解决的那个问题）
    /// - 等一等就好（网络不通 / 网关不在）→ 继续退避，状态没坏
    /// - 拿不到且不会自己好（未配对 / 关系被撤销）→ **停**。再试是纯空转
    private func renewThenRetry() {
        guard active else { return }
        // 必须先离开 `.connecting`：这一代没有建出连接，而 `connect` 早在前几步就把它置成了
        // `.connecting`。留着它，换到票之后 `reconnectNow` 会以「正在握手」为由拒绝。
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
                self.reconnectNow()
            case .retryLater:
                self.scheduleReconnect()
            case .unavailable:
                Log.warn(Log.Module.session,
                         "no ticket and none obtainable — stopping the follow loop")
                self.phase = .idle
            }
        }
    }

    /// 退避重连 —— 延迟由 `StreamBackoff` 决定。
    private func scheduleReconnect() {
        guard active else { return }
        // 单飞：本拍取代尚未触发的那一拍。不取代的话两个定时器各起一条连接，后起的那条把
        // 先起的掐死、先起的失败回调再排一次，于是 attempt 编号跳着走、退避爬不到上限。
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1

        let delay = StreamBackoff.delayMs(
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
