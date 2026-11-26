/**
 * 这一屏的读数与翻页：还能不能往前翻、翻的过程中什么状态、结果怎么告知，以及三格展示值。
 *
 * 消费者是 `SessionSync`（六个读口与 `loadOlder` 的转发、装配时的两条出线）与投影的两条接线
 * （判定、一条数据帧到达）。它不持投影、不持连接与订阅 —— 只吃「窗口事实」与「投影的产出」。
 *
 * 三件事同处一处：翻页的判定（页数上限、缺口不重试、失败两种说法、何时收工）、读数与物化同一拍
 * （`refreshCounts` 由协调者的 `refreshView` 在 `projection.refresh()` 之后调）、告知的置位规则。
 */

import Foundation

@MainActor
@Observable
final class SessionReadings {

    private let client: RpcClient
    private let sessionId: String
    /// 窗口事实与三个翻页动作 —— 位置只从这里读，不另算一份。
    private let input: SessionInput
    /// 状态行 —— 共享对象，翻页那五处写入写的是同一个。
    private let statusBox: SessionStatus

    // MARK: - 视图读的六格

    /// 窗口里的事件条数（消息只是其中一部分）。
    private(set) var eventCount = 0
    /// 还能往回翻吗。为真时界面给出入口。
    private(set) var hasMore = false
    /// 正在往回翻页 —— 与状态行分开：界面要的是「顶部在等」。
    private(set) var isPagingOlder = false
    /// 「对不上」的告知 —— 底部固定面的数据源。
    private(set) var notice: ResyncNotice?
    /// 上下文占用；`nil` 时格子显示 `--` 而不消失（消失会让模型格横移）。
    private(set) var usage: UsagePayload? = nil
    /// 最后一次收到数据帧的时刻。**不参与观察**：每帧都变，被追踪会让合并刷新失效。
    @ObservationIgnored
    private(set) var lastFrameAt: Date? = nil

    /// 同一时刻只允许一次读请求（翻页）。
    private var syncInFlight = false
    /// 告知的判定（置位与清除的唯一来源）—— 视图只读 `notice`。
    private var noticeState = ResyncNoticeState()
    /// 占用值的吸收，判定在 `UsageState`。
    private var usageState = UsageState()

    // MARK: - 接线（由装配点在 `init` 之后接上）

    /// 该刷一屏了 —— 物化在协调者那一侧（它还要顺带把两个计数重算）。
    var onRefreshNeeded: (() -> Void)?
    /// 位置被否定：整段重建。七步的顺序在协调者手里，这里只叫一声。
    var onRebuildNeeded: (() -> Void)?

    init(client: RpcClient, sessionId: String, input: SessionInput, statusBox: SessionStatus) {
        self.client = client
        self.sessionId = sessionId
        self.input = input
        self.statusBox = statusBox
    }

    // MARK: - 读数

    /// 两个计数从窗口事实重算。**由 `refreshView` 在物化之后调** —— 与快照同一拍，
    /// 否则视图会读到「新快照配旧条数」，而这类错只在切屏那一帧可见。
    func refreshCounts() {
        eventCount = input.records.count
        hasMore = input.hasMore
    }

    /// 收下一条判定 —— 置位规则在 `ResyncNoticeState`。
    ///
    /// 只有 `.resetRequired` 会置位（缺口与水位回退两种原因）；拒帧与传输失败只写状态行。
    func noteVerdict(_ verdict: Verdict) {
        noticeState.observe(verdict)
        notice = noticeState.notice
    }

    /// control 送来的一条占用：权威，直接覆盖。
    ///
    /// **先记时刻再判**：被丢弃的帧也证明链路活着，所以「收到」与「采纳」是两件事。
    func noteUsage(_ payload: UsagePayload?) {
        noteFrame()
        usageState.adopt(payload)
        usage = usageState.usage
    }

    /// 打开帧的投影基线：**control 到达之前**的初值。之后 control 的投影会按水位覆盖它。
    func applyUsage(_ snapshot: UsageSnapshot) {
        // 同上：置位在判之前。
        noteFrame()
        guard usageState.apply(snapshot) == .accepted else { return }
        usage = usageState.usage
    }

    /// 一条数据帧到达。它只有观测价值，不参与重绘（`@ObservationIgnored`）。
    func noteFrame() { lastFrameAt = Date() }

    // MARK: - 翻页

    /// 往回翻一段更早的历史；一页没有可显示的内容时接着往前（上限 3 页）。
    ///
    /// `visibleNodeCount` 是「视图那一列现在有几条」—— 判断这一页有没有长出东西。由调用方
    /// 每轮现取，而不是本单元持有：它属于协调者那一侧的形状。
    func loadOlder(visibleNodeCount: () -> Int) async {
        guard !syncInFlight, input.hasMore else { return }
        // 翻页低频，打 info：真机上要能对照「我没点它却加载了」。
        Log.info(Log.Module.session, "loadOlder",
                 ["seq": String(input.windowStart), "count": String(input.records.count)])
        syncInFlight = true
        isPagingOlder = true
        defer {
            syncInFlight = false
            isPagingOlder = false
        }
        statusBox.set(.syncing)

        // 上限 3 页：再多说明服务端在挤牙膏，让用户看见状态行比继续闷拉更有用。
        for _ in 0..<3 {
            // **在取页之前取基线**：放到刷新之后，「有进展」恒为假，每页都当成挤牙膏。
            let nodesBefore = visibleNodeCount()
            guard let verdict = await fetchOlderPage() else { return }

            switch verdict {
            case .merged(let count):
                statusBox.set(.done(added: count, recovered: false))
            case .caughtUp:
                statusBox.set(.done(added: 0, recovered: false))
            case .resetRequired(let reason):
                // 更早的历史接不上不影响当前视图的真实性：`.gap` 保留（清空等于用
                // 「你多点一下」换掉已读到的全部内容），只有位置被否定才清空重来。
                if reason.invalidatesLocalContent { onRebuildNeeded?() }
                noteVerdict(verdict)
                onRefreshNeeded?()
                return
            case .refused(let code):
                statusBox.set(.failed(step: .paging, cause: .refusal(code: code)))
                onRefreshNeeded?()
                return
            case .failed:
                statusBox.set(.failed(step: .paging, cause: .transport))
                onRefreshNeeded?()
                return
            }

            onRefreshNeeded?()
            // 这一页真的多了可显示的东西，或者已经到日志开头 —— 收工。
            if visibleNodeCount() > nodesBefore || !input.hasMore { return }
        }
    }

    /// 一次往回翻的请求。`nil` = 没拿到发起权（有在途请求）。
    private func fetchOlderPage() async -> Verdict? {
        guard input.beginRequest() else { return nil }
        do {
            let page = try await readPage(client, sessionId: sessionId,
                                          throughSeq: input.throughSeq,
                                          beforeSeq: input.windowStart)
            return input.prepend(page)
        } catch let error as RpcClientError {
            input.abandonRequest()
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            input.abandonRequest()
            return .failed
        }
    }
}
