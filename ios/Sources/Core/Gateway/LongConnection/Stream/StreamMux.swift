/**
 * 流表：这条连接上开着哪几条流，以及每条流自己的编号、退避与「这一次尝试」。
 *
 * 它不认识 socket（都经 `Channel`），也不认识业务（判读是造流时注入的 `StreamBehavior`）。
 * `LogicalStream` 的四个可变字段是 `fileprivate`，构造入口只有 `makeStream` 一条。
 */
import Foundation

/**
 * 一条流 —— 业务手里的一等对象，也是流表里的那一行。
 * 公开面只有四样：编号、标签、关自己、重开自己；没有连接级动作。
 */
@MainActor
final class LogicalStream {

    fileprivate let behavior: any StreamBehavior
    /// 登记顺序。只用于「谁先开的」这类诊断与稳定排序；帧的归属按编号，不看它。
    fileprivate let sequence: Int

    fileprivate(set) var id: StreamId
    /// 当前编号对应的开流文本。换号时一起换 —— 文本里的号与信封里的号必须是同一个。
    fileprivate(set) var text: String
    fileprivate(set) var retryAttempt = 0
    /// 「已发出 open、还没收到开口帧」的那一段。
    fileprivate(set) var openInFlight = false
    /// 这一条流是否已经开出去过。再开一次就是新的开流，要新号。
    fileprivate(set) var openedAtLeastOnce = false
    /// 本次开流尝试的令牌（开流超时靠它判「还是不是这一次」）。
    fileprivate(set) var attempt: StreamAttempt?
    fileprivate var retryWorkItem: DispatchWorkItem?
    fileprivate weak var owner: StreamMux?

    fileprivate init(behavior: any StreamBehavior, sequence: Int, id: StreamId, text: String) {
        self.behavior = behavior
        self.sequence = sequence
        self.id = id
        self.text = text
    }

    /// 日志里认人的标识。
    var label: String { behavior.label }

    /// 关掉自己：发一条取消帧、从表里摘掉。**连接与别的流不动。**重复调用是幂等的。
    func close() { owner?.close(self) }

    /// 换一个编号在现有连接上重开：基线丢了、或用户按了「重试」。连接与别的流不动。
    func restart() { owner?.restart(self) }
}

/**
 * 流表本体。存活范围是一条连接：收尾时整表清空，换代次时每条已开过的流换新号重开。
 */
@MainActor
final class StreamMux {

    /// 开流超时：从每一次开流尝试起算。45 秒 = 打开帧上界 4 MiB 在慢链路（约 125 KB/s）的
    /// 传输时间加建连；且必须**短于**连接层的判死窗口，否则同刻触发、退化成整条连接重连。
    /// 可写是为了让这条路径能被观测。
    var openTimeout: TimeInterval = 45

    private weak var channel: (any Channel)?
    private var byId: [StreamId: LogicalStream] = [:]
    private var registrations = 0
    /// 已建成的流编号。阶段说连接，这个集合说每条流 —— 只在本文件里读写。
    private var established: Set<StreamId> = []

    /// 接上传输层，并订阅它发的那两个事实（停用、换代次）。
    /// 订阅在这里而不是装配层：状态在本表，反应也只能由本表做；弱引用，反向只需能喊话。
    func attach(channel: any Channel) {
        self.channel = channel
        channel.onStopped = { [weak self] in self?.closeAll() }
        channel.onGenerationChange = { [weak self] in self?.reopenAll() }
    }

    // MARK: - 造流与关流

    /// 造一条流并登记。
    /// **不幂等**：同一业务调两次就是两条流、两个编号，业务要自己只造一次。
    /// - Returns: 造好的流；`build` 抛错时 `nil`。
    @discardableResult
    func makeStream(_ behavior: any StreamBehavior) -> LogicalStream? {
        guard let fresh = mint(behavior) else { return nil }
        registrations += 1
        let stream = LogicalStream(
            behavior: behavior, sequence: registrations, id: fresh.id, text: fresh.text
        )
        stream.owner = self
        byId[fresh.id] = stream
        // 有连接就立刻开出去；没有就让传输层去建一条（它自己判要不要动）。
        if channel?.attempt != nil {
            sendOpen(stream)
        } else {
            channel?.ensureConnected()
        }
        return stream
    }

    /// 关掉一条流：一条取消帧 + 摘条目。晚到的关不碰后来者（按编号与对象双重核对）。
    func close(_ stream: LogicalStream) {
        guard byId[stream.id] === stream else { return }
        sendCancel(stream.id)
        forget(stream)
    }

    /// 立刻换号重开一条流（不进退避）。
    func restart(_ stream: LogicalStream) {
        guard byId[stream.id] === stream else { return }
        stream.retryWorkItem?.cancel()
        stream.retryWorkItem = nil
        stream.retryAttempt = 0
        // 先取消旧号：同号重开时网关的流表里可能还占着它，而占用中的打开会被直接忽略。
        sendCancel(stream.id)
        established.remove(stream.id)
        stream.openInFlight = false
        guard renumber(stream) else { return }
        if channel?.attempt != nil {
            sendOpen(stream)
        } else {
            channel?.ensureConnected()
        }
    }

    // MARK: - 收帧

    /// 一帧到了：按编号归流，交给业务判，照它回的两句话办。
    /// 编号不在表里的帧什么都不做 —— 那是上一条流的尾巴。
    func receive(_ envelope: MuxServerEnvelope, raw: Data) {
        guard let stream = byId[envelope.streamId] else { return }
        apply(stream.behavior.handle(envelope, raw: raw), to: stream)
    }

    private func apply(_ reply: StreamReply, to stream: LogicalStream) {
        if reply.establishes {
            // 建成即退避归零：一次成功不该被上一段失败的账拖住。
            stream.openInFlight = false
            stream.retryAttempt = 0
            established.insert(stream.id)
        }
        switch reply.next {
        case .keep:
            break
        case .reopen:
            restart(stream)
        case .retry:
            scheduleRetry(stream)
        case .stop:
            // 终态：再开也是同一个结果。收起这一条 —— 连接与别的流不动。
            forget(stream)
        }
    }

    // MARK: - 连接换代次 / 收尾

    /// 换代次：每条已开过的流换新号重开，第一次开出去的流用登记时造的那个号。
    private func reopenAll() {
        established.removeAll()
        for stream in orderedStreams() {
            if stream.openedAtLeastOnce {
                guard renumber(stream) else { continue }
            }
            // 每条流各记一行：连接层不再报「这一代挂着谁」，重开了哪些只有这里说得清。
            Log.info(Log.Module.session, "[\(stream.label)] reopened on g\(channel?.attempt?.generation ?? 0)")
            sendOpen(stream)
        }
    }

    /// 连接收尾：清空登记，**不发帧**（线都没了，帧发不出去）。
    private func closeAll() {
        for stream in Array(byId.values) { forget(stream) }
    }

    /// 这条流是否排着一拍退避。对测试可读：它是「退避真的排上了」的唯一观测点。
    func isWaitingToRetry(_ stream: LogicalStream) -> Bool {
        byId[stream.id] === stream && stream.retryWorkItem != nil
    }


    // MARK: - 编号与重开

    /// 造一个新编号并让业务拼出文本 —— 造号与拼装是同一步的两半，分开写迟早漏掉一半。
    private func mint(_ behavior: any StreamBehavior) -> (id: StreamId, text: String)? {
        let id = Self.newStreamId()
        do {
            return (id, try behavior.build(id))
        } catch {
            // 编不出来意味着形状自己坏了：开一条注定看不懂的流只会让屏幕停在「正在同步…」。
            Log.error(Log.Module.session, "open frame encoding failed — not opening the stream")
            return nil
        }
    }

    /// 新编号 —— 全仓唯一的造号点，且不复用（复用会让旧流的收尾删到新流、残帧同号）。
    static func newStreamId() -> StreamId {
        UUID().uuidString.lowercased()
    }

    /// 换一个新编号并让业务重新拼文本，表里的键跟着换。
    private func renumber(_ stream: LogicalStream) -> Bool {
        guard let fresh = mint(stream.behavior) else { return false }
        byId.removeValue(forKey: stream.id)
        stream.id = fresh.id
        stream.text = fresh.text
        byId[fresh.id] = stream
        return true
    }

    /// 在这一条流上发出它的开流内容。
    private func sendOpen(_ stream: LogicalStream) {
        // 这一次尝试还没建成：旧编号的「建成」不成立，否则开流超时会照着旧账判。
        established.remove(stream.id)
        stream.openInFlight = true
        stream.openedAtLeastOnce = true
        channel?.send(stream.text)
        armOpenTimeout(stream)
    }

    private func sendCancel(_ id: StreamId) {
        guard let text = try? MuxCancelFrame(streamId: id).encoded() else {
            Log.warn(Log.Module.session, "cancel frame encoding failed for stream \(id)")
            return
        }
        channel?.send(text)
    }

    /// 开流超时：按流各起一个，判据是「还是这一次尝试」。
    private func armOpenTimeout(_ stream: LogicalStream) {
        guard let token = channel?.attempt else { return }
        stream.attempt = token
        let id = stream.id
        let budget = openTimeout
        let label = stream.label
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard let self, self.channel?.attempt == token, self.byId[id] === stream,
                  stream.openInFlight, !self.established.contains(id) else { return }
            // 这一行是「这条流为什么没开成」的第一现场。只重开这一条：连接自有判死窗口兜着。
            Log.warn(Log.Module.session,
                     "[\(label)] opening timeout (\(Int(budget))s) — reopening this stream only")
            self.scheduleRetry(stream)
        }
    }

    // MARK: - 按流退避

    /// 这条流被拒但值得再试：旧号当场作废，新号等退避到了再发（等待期不再受开流超时管）。
    private func scheduleRetry(_ stream: LogicalStream) {
        sendCancel(stream.id)
        established.remove(stream.id)
        stream.openInFlight = false
        // 新号当场就位，只是还没发出去：于是这条流的编号始终是「下一个要用的」。
        guard renumber(stream) else { return }

        stream.retryAttempt += 1
        let delay = Backoff.delayMs(
            attempt: stream.retryAttempt, random: Double.random(in: 0..<1)
        )
        stream.retryWorkItem?.cancel()
        Log.info(Log.Module.session, "stream [\(stream.label)] retry in \(delay)ms (attempt \(stream.retryAttempt))")
        let work = DispatchWorkItem { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.retryNow(stream)
        }
        stream.retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }

    /// 退避到点那一拍要不要真的发 open。
    /// **在途**挡「同一个号被开两次」（网关判协议违规、直接关连接），**已建成**挡没必要的重开。
    /// 抽成纯函数是为了让它可断言：等待期里的帧分不清是这一拍还是重连发的。
    static func shouldOpenOnRetry(openInFlight: Bool, established: Bool) -> Bool {
        !openInFlight && !established
    }

    private func retryNow(_ stream: LogicalStream) {
        guard byId[stream.id] === stream else { return }
        stream.retryWorkItem = nil
        guard Self.shouldOpenOnRetry(
            openInFlight: stream.openInFlight, established: established.contains(stream.id)
        ) else { return }
        if channel?.attempt != nil {
            sendOpen(stream)
        } else {
            channel?.ensureConnected()
        }
    }

    /// 从表里摘掉一条流。**不发帧** —— 该不该取消由调用方决定。
    private func forget(_ stream: LogicalStream) {
        guard byId.removeValue(forKey: stream.id) != nil else { return }
        stream.retryWorkItem?.cancel()
        stream.retryWorkItem = nil
        established.remove(stream.id)
    }

    /// 按登记顺序排好的流：开流、日志、换代次重开都跟着这个次序。
    private func orderedStreams() -> [LogicalStream] {
        byId.values.sorted { $0.sequence < $1.sequence }
    }
}
