/**
 * 本屏那一条订阅流的开关：开、关、只重开这一条。
 *
 * 与连接层的分工：连接是 App 级的、由长连接自己管；这里只管「本屏要不要一条流、要哪一条」。
 * 连接与别的流一个都不动 —— `retry()` 是流级动作，不是重连。
 *
 * 首屏兜底也归这里：它是「流迟迟不给窗口」时的另一条取数路，与开流同一个决定。
 * 取数本身不在这里 —— 那是读侧编排的事，用闭包交进来。
 */
import Foundation

@MainActor
@Observable
final class SessionFollowing {

    /// 造一条流。由宿主给：编号由流表发，行为对象要指向本屏的读侧。
    /// `nil` = 这一次开流放弃（开流文本编不出来）—— 那正是首屏兜底存在的理由。
    private let makeStream: () -> LogicalStream?
    /// 手里还空不空 —— 首屏兜底只在空的时候兜。
    private let isTranscriptEmpty: () -> Bool
    /// 走 HTTP 取一次窗口。兜底路径与正常同步同一条。
    private let syncNow: () async -> Void

    /// 本屏那一条流。关它、重开它都是它自己的方法。
    private var stream: LogicalStream?
    /// 首屏兜底：WS 迟迟不给窗口时用 HTTP 拉一次，`opening` 到达即取消。
    private var firstScreenFallback: Task<Void, Never>?

    /// 2.5 秒是「明显慢了」与「还在握手」的分界。
    private static let firstScreenDelay: Duration = .seconds(2.5)

    init(
        makeStream: @escaping () -> LogicalStream?,
        isTranscriptEmpty: @escaping () -> Bool,
        syncNow: @escaping () async -> Void
    ) {
        self.makeStream = makeStream
        self.isTranscriptEmpty = isTranscriptEmpty
        self.syncNow = syncNow
    }

    /// 进会话详情即登记一条流。
    func start() {
        // 一次屏幕只造一条：重复调用不换号、也不多一条流（视图重算会让这里被调多次）。
        guard stream == nil else { return }
        stream = makeStream()
        // 首屏兜底与开流成败无关：编不出帧时它是唯一还能把内容送到屏幕上的路。
        scheduleFirstScreenFallback()
    }

    /// 只重开这一条流 —— 流级动作，不动连接与别的流。
    ///
    /// 两个来由：用户点了「重试」，或者未定稿基线丢了、后续 chunk 接不上。同一个动作，
    /// 所以只有这一个入口 —— 分成两个方法只会让「哪一个才是真的重开」变成要读实现才知道的事。
    func retry() {
        stream?.restart()
    }

    /// 离开会话详情：注销这条流、停掉兜底。连接留在原处（App 级）。
    func stop() {
        firstScreenFallback?.cancel()
        firstScreenFallback = nil
        stream?.close()
        stream = nil
    }

    /// opening 到了：兜底没有意义了。
    func cancelFirstScreenFallback() {
        firstScreenFallback?.cancel()
        firstScreenFallback = nil
    }

    private func scheduleFirstScreenFallback() {
        firstScreenFallback?.cancel()
        firstScreenFallback = Task { [weak self] in
            try? await Task.sleep(for: Self.firstScreenDelay)
            guard !Task.isCancelled, let self, self.isTranscriptEmpty() else { return }
            Log.info(Log.Module.session, "first-screen fallback: ws silent, fetching over http")
            await self.syncNow()
        }
    }
}
