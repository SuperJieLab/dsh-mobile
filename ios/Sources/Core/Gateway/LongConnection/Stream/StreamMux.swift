/**
 * 流表：这条连接上开着哪几条流，以及每条流自己的编号、退避与「这一次尝试」。
 *
 * 它不认识 socket：发文本、要连接两件事都经 `Channel`（由 WebSocket 层实现）。
 * 它也不认识业务：每条流的判读是造流时注入的 `StreamBehavior`。
 *
 * `LogicalStream` 与流表住同一个文件，是刻意的 —— 流的四个可变字段（编号 / 文本 /
 * 退避档位 / 在途标记）是 `fileprivate`：只有本文件能写，编译器替「业务侧改不到它们」
 * 这句话把关；构造入口同样只有 `makeStream` 一条。跨层的两个形状（`Channel` /
 * `StreamAttempt`）不掌握任何可变状态，各住自己的文件。
 */
import Foundation

/**
 * 一条流 —— 业务手里的一等对象，也是流表里的那一行。
 *
 * 公开面只有四样：编号（读）、标签（读）、关自己、重开自己。它**没有**连接级动作 ——
 * 「一条流被拒」与「整条连接断了」是两件事，后者不该从这里写得出来。
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
 * 流表本体。
 *
 * 存活范围是一条连接：连接收尾时整表清空（不发帧），换代次时每条已开过的流换新号重开。
 * 一条流的失败只带走它自己 —— 泵的异常由业务折成答复（`StreamReply.next`），本层照办。
 */
@MainActor
final class StreamMux {

    /// 开流超时：从**每一次开流尝试**起算，多久没等到开口帧就当这次尝试没成。
    ///
    /// 45 秒不是拍的：打开帧是这条流里最大的一帧，慢链路实测约 125 KB/s，而两端约定的
    /// 打开帧上界是 4 MiB ⇒ 约 34 秒，加建连约 2 秒。两端任一侧改了上界，这个数要重算。
    ///
    /// 它还必须**短于**连接层的判死窗口：到点后本层要先把「只重开这一条」做完，
    /// 连接层才轮到判死。两者同值时会在同一刻触发，行为退化成整条连接重连。
    ///
    /// 做成可变不是为了灵活性，是为了让这条路径**能被观测**：拨到几十毫秒就在测试里看得见
    /// 它发生，而不是只活在文档里。
    var openTimeout: TimeInterval = 45

    private weak var channel: (any Channel)?
    private var byId: [StreamId: LogicalStream] = [:]
    private var registrations = 0
    /// 已建成的流编号。阶段说连接，这个集合说每条流 —— 只在本文件里读写。
    private var established: Set<StreamId> = []

    /// 接上传输层，并订阅它发的那两个事实：停用、换代次。
    ///
    /// 订阅在这里而不是装配层：状态在本表，反应也只能由本表做 —— 让上级接事件再回调，
    /// 等于在装配层又开一个能改流表的入口。弱引用：传输层持有本对象，反向只需能喊话。
    func attach(channel: any Channel) {
        self.channel = channel
        channel.onStopped = { [weak self] in self?.closeAll() }
        channel.onGenerationChange = { [weak self] in self?.reopenAll() }
    }

    // MARK: - 造流与关流

    /// 造一条流并登记。
    ///
    /// **不幂等**：同一业务调两次就是两条流、两个编号。流以对象自身为身份，所以
    /// 「重复调用安全」这件事不再成立 —— 业务要负责只造一次（各自的一次性闸）。
    ///
    /// - Returns: 造好的流；`build` 抛错时返回 `nil`（那一次开流放弃）。
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
    ///
    /// 编号不在表里的帧什么都不做 —— 那是上一条流的尾巴，放它进判读器最轻是一次没必要的
    /// 跳号重开，最重是用上一个会话的窗口覆盖这一屏。
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

    /// 新编号 —— 全仓唯一的造号点，且不复用。
    ///
    /// 复用会让旧流的收尾删到新流的登记，也会让旧流的残帧与新流同号。
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
            // 这一行是「这条流为什么没开成」的第一现场。
            //
            // 只重开这一条：连接自有它的判死窗口兜着（且比这个超时更长），流层只管流。
            // 一条流开不起来，不该把同一连接上的别的流一起带走。
            Log.warn(Log.Module.session,
                     "[\(label)] opening timeout (\(Int(budget))s) — reopening this stream only")
            self.scheduleRetry(stream)
        }
    }

    // MARK: - 按流退避

    /// 这条流被拒但值得再试：旧号当场作废，新号等退避到了再发。
    ///
    /// 等待期间这条流不在等开口帧 —— 于是它不会被自己的开流超时反复重开。
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
    ///
    /// 两个条件各挡一种重复：**在途**挡「同一个号被开两次」（网关把重复编号判成协议违规、
    /// 直接关连接），**已建成**挡「没必要的重开」。两种都不是「退避错了」，而是这一拍
    /// 已经被别的东西 —— 重连、或用户手按的重试 —— 提前满足了。
    ///
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

    /// 从表里摘掉一条流。**不发帧** —— 该不该取消由调用方决定：注销要取消，
    /// 服务端已经收尾的那一条不要。
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
