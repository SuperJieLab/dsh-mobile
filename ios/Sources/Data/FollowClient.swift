import Foundation

/**
 * 跟随流的连接编排 —— `URLSessionWebSocketTask` 上的三件事：
 *
 * 1. **代次**：本地单调计数。每一次（重）连接都是新代次，旧代次的任何回调一律
 *    丢弃 —— 重连竞态下，迟到的一条旧帧不能污染新代次的视图。
 * 2. **退避重连**：base 500ms × 2^n，抖动取 50–100%，封顶 10s，就绪硬超时 15s
 *    —— 参数照抄上游（`recovery-config.ts:26-30`）。**重连即重新 open**：新
 *    opening 重建窗口，不做水位续传（docs/plans/M2-realtime-transient.md §3.4）。
 * 3. **心跳**：2s 一次 ping，连续 2 次没等到 pong 就当连接已死，走重连 ——
 *    参数照抄上游（`stream-server.ts`）。URLSession 会自动回服务端的 ping，
 *    这里管的是「对面还活着吗」这一侧。
 *
 * 它不解释任何帧：解析成 JSON 后原样递给回调，形状与语义都在编排层之外
 * （`SessionSync`）。协议名、端口全从 `GatewayClient.baseURL` 推导 ——
 * 全 App 仍然只有一个要改的地址。
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

    /// opening 帧：`{sessionId, cursor, pageStart, hasOlder, events, assistantStream?}`。
    var onOpening: ((JSONValue) -> Void)?
    /// 一条持久事件（DSH 事件对象原样）。
    var onEvent: ((SessionEvent) -> Void)?
    /// 一条瞬态帧（start/chunk/end，原样）。
    var onTransient: ((JSONValue) -> Void)?
    /// 一条 error 帧 —— 流通道里的协议内拒绝。
    var onRefused: ((GatewayFailure) -> Void)?
    /// 连接阶段变化（连接态指示器的数据源，M3）。
    var onPhaseChange: ((Phase) -> Void)?

    // MARK: - 状态

    @Published private(set) var phase: Phase = .idle

    /// 连接代次 —— 每次连接递增；回调带着发起时的代次，对不上就丢。
    private var generation = 0
    private var sessionId: String?
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var missedPongs = 0
    /// 重连定时器 —— teardown 时要能取消。
    private var reconnectWorkItem: DispatchWorkItem?

    /// 就绪硬超时：升级成功后 15s 内没收到 opening，就当这次连接没成。
    private let readyTimeout: TimeInterval = 15
    private let pingInterval: TimeInterval = 2
    private let maxMissedPongs = 2

    private static let streamPath = "/rpc/stream"
    private static let streamId = 1
    private static let baseBackoffMs = 500
    private static let maxBackoffMs = 10_000

    /// 是否仍在跟随（`stop()` 之后一切重连都停）。
    private var following = false

    // MARK: - 生命周期

    /// 开始跟随一个会话。重复调用同一会话是幂等的；换会话会先停旧的。
    func start(sessionId newSessionId: String) {
        if following, sessionId == newSessionId { return }
        stop()
        following = true
        sessionId = newSessionId
        connect()
    }

    /// 停止跟随：关连接、取消一切定时器。之后不再重连。
    func stop() {
        following = false
        sessionId = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTask()
        generation += 1 // 旧代次的一切回调就此作废
        phase = .idle
    }

    /// 重开当前流：用于瞬态断号 —— 现有连接还活着，但这一段的基线已经丢了。
    /// 重新 open（同一条连接上）拿新 opening；连接本身不重建。
    func reopenStream() {
        guard following, let sessionId else { return }
        openFollowStream(sessionId: sessionId)
    }

    /// 回前台立即触发一次重连 —— 上游「恢复立即试」（online 事件 → 重连控制器）
    /// 的复现（M3）。退避窗口里的等待被跳过；已在握手或就绪的连接不受影响，
    /// 不叠加并发连接。
    func reconnectNow() {
        guard following, sessionId != nil else { return }
        guard phase != .ready, phase != .connecting else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        print("[FollowClient] foreground — reconnecting immediately (skipping backoff)")
        connect()
    }

    // MARK: - 连接

    private func connect() {
        guard following, sessionId != nil else { return }
        // 注意：不在这里清零 reconnectAttempt —— 退避档位必须随失败次数爬升，
        // 否则握手持续失败时会退化成每秒一次的疯狂循环（真机抓到过）。
        generation += 1
        let current = generation
        phase = .connecting

        // 上一代次的连接必须先关掉：不关的话旧 socket 的 receive/heartbeat
        // 还在（回调虽被代次拦住，连接本身泄漏），且系统的连接行为会互相干扰。
        if task !== nil {
            print("[FollowClient] g\(current) closing previous task before connecting")
            closeTask()
        }

        guard var components = URLComponents(url: GatewayClient.defaultBaseURL, resolvingAgainstBaseURL: false) else {
            phase = .idle
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = Self.streamPath

        let webSocketTask = URLSession.shared.webSocketTask(with: components.url!)
        task = webSocketTask
        print("[FollowClient] connect g\(current) → \(components.url!)")
        webSocketTask.resume()

        // 握手由系统完成，open 帧立即发出（未就绪的连接会替我们排队）——
        // 服务端等的就是它：没有 open，永远不会有 opening。
        if let sessionId {
            print("[FollowClient] g\(current) sending open for \(sessionId)")
            openFollowStream(sessionId: sessionId)
        }

        // 就绪硬超时：15s 内没收到 opening 就断开走重连。
        // ⚠️ 括号必须显式：`?? 15 * 1e9` 会把「15」当纳秒传进去（真机抓到过 ——
        // 每次连接立即超时，open 帧被 cancel 成 -999，永远收不到 opening）。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.readyTimeout ?? 15) * 1_000_000_000))
            guard let self, self.generation == current, self.task === webSocketTask, self.phase != .ready else { return }
            print("[FollowClient] g\(current) ready timeout (\(Int(self.readyTimeout))s) — closing and retrying")
            self.closeTask()
            self.scheduleReconnect()
        }

        receiveLoop(on: webSocketTask, generation: current)
        heartbeat(on: webSocketTask, generation: current)
    }

    /// 在当前连接上发一条 open 帧，开始（或重建）跟随流。
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
    }

    /// 关掉当前任务并使其回调作废（代次在外层管）。
    private func closeTask(from caller: String = #function) {
        if let task {
            print("[FollowClient] g\(generation) closeTask from \(caller)")
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
                    print("[FollowClient] g\(current) receive failed: \(error)")
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
        guard case .string(let text) = message else {
            print("[FollowClient] g\(current) non-text frame ignored")
            return
        }
        guard let frame = try? JSONDecoder().decode(MuxFrame.self, from: Data(text.utf8)) else {
            print("[FollowClient] g\(current) unparsable frame (first 120 chars): \(text.prefix(120))")
            return // 解不了的帧不是消息，忽略
        }
        print("[FollowClient] g\(current) frame: \(frame.type)")

        switch frame.type {
        case "item":
            guard let payload = frame.payload else { return }
            if payload["sessionId"] != nil && payload["cursor"] != nil && payload["events"] != nil {
                // opening：就绪的标志。
                reconnectAttempt = 0
                missedPongs = 0
                phase = .ready
                onOpening?(payload)
            } else if payload["type"]?.string == "assistant-stream" {
                onTransient?(payload["frame"] ?? .null)
            } else if let event = payload.sessionEvent {
                onEvent?(event)
            }

        case "error":
            let failure = GatewayFailure(
                code: frame.payload?["code"]?.string ?? "internal-error",
                message: frame.payload?["message"]?.string ?? ""
            )
            onRefused?(failure)
            // 会话级终态（不存在 / 读不出来）重连无意义；其余退避重连。
            if failure.code == GatewayErrorCode.unknownSession.rawValue
                || failure.code == GatewayErrorCode.unreadableSession.rawValue {
                stop()
            } else {
                closeTask()
                scheduleReconnect()
            }

        case "end":
            // 流被服务端正常收尾 —— 重开一个（例如服务端主动收尾的会话）。
            if let sessionId { openFollowStream(sessionId: sessionId) }

        default:
            break
        }
    }

    // MARK: - 发

    private func send(_ json: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(json),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    // 握手没完成或连接已死时 send 会在这里失败 —— 这是
                    // 「发了 open 却收不到任何帧」最常见的原因，必须留痕。
                    print("[FollowClient] g\(self?.generation ?? -1) send failed: \(error)")
                    self?.closeTask()
                    self?.scheduleReconnect()
                }
            }
        }
    }

    // MARK: - 心跳与退避

    private func heartbeat(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        Task { [weak self] in
            while let self, self.generation == current, self.task === webSocketTask, self.following {
                try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                guard self.generation == current, self.task === webSocketTask else { return }
                self.missedPongs += 1
                if self.missedPongs > self.maxMissedPongs {
                    // 对面不再回 pong：半开连接，当它死了。
                    self.closeTask()
                    self.scheduleReconnect()
                    return
                }
                webSocketTask.sendPing { [weak self] error in
                    Task { @MainActor [weak self] in
                        // pong 回来了（completion 无错即 pong 已达）。
                        if error == nil { self?.missedPongs = 0 }
                    }
                }
            }
        }
    }

    /**
     * 重连延迟：base 500ms × 2^n，抖动取封顶值的 50–100%，封顶 10s。
     *
     * 抽成纯函数（`random` 注入）是因为它是这段编排里唯一**可断言**的行为：
     * 曲线对不对、抖动范围对不对，都能在不碰 socket 的情况下验证。完整的
     * 「断线 → 退避 → 重连 → 代次递增」编排需要真网络，由真机判据 R3/R4 覆盖。
     *
     * - Parameters:
     *   - attempt: 第几次重连（从 1 起）。
     *   - random: 抖动采样，`0..<1`。
     */
    static func backoffDelayMs(attempt: Int, random: Double) -> Int {
        // attempt 1 是第一次重连，指数从 2^0 起。
        let exponent = min(max(attempt, 1), 16) - 1
        let cap = min(baseBackoffMs * (1 << exponent), maxBackoffMs)
        return Int(Double(cap) * (0.5 + min(max(random, 0), 1) * 0.5))
    }

    /// 退避重连：base 500ms × 2^n，抖动 50–100%，封顶 10s。
    private func scheduleReconnect() {
        guard following, sessionId != nil else { return }
        phase = .waiting(ms: 0)
        reconnectAttempt += 1

        let delay = Self.backoffDelayMs(attempt: reconnectAttempt, random: Double.random(in: 0..<1))

        print("[FollowClient] reconnect in \(delay)ms (attempt \(reconnectAttempt))")
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

private extension JSONValue {
    /// 若这个 payload 是一条事件（有 `type` 与 `seq`），解成 `SessionEvent`。
    /// 不是事件（opening、瞬态包装）就是 `nil`。
    var sessionEvent: SessionEvent? {
        guard self["type"]?.string != nil, self["seq"] != nil else { return nil }
        return try? JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(self))
    }
}
