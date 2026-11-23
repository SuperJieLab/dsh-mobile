/**
 * 本屏那一条订阅流的开关：开、关、只重开这一条。
 *
 * 与连接层的分工：连接是 App 级的、由长连接自己管；这里只管「本屏要不要一条流、要哪一条」。
 * 连接与别的流一个都不动 —— `retry()` 是流级动作，不是重连。
 *
 * **没有兜底**：从前这里有一个 2.5 秒的「WS 迟迟不给窗口就改用 HTTP 拉一次」。
 * 那条路把同一屏的两个来源（流 / HTTP）并进同一个镜像，各自算一份水位；第 2 期起
 * 打开帧是唯一的来源，兜底连同它要的那些参数一起删了。
 */
import Foundation

@MainActor
@Observable
final class SessionFollowing {

    /// 造一条流。由宿主给：编号由流表发，行为对象要指向本屏的读侧。
    /// `nil` = 这一次开流放弃（开流文本编不出来）—— 此时屏幕是空的，状态行说「还没连上」。
    private let makeStream: () -> LogicalStream?

    /// 本屏那一条流。关它、重开它都是它自己的方法。
    private var stream: LogicalStream?

    init(makeStream: @escaping () -> LogicalStream?) {
        self.makeStream = makeStream
    }

    /// 进会话详情即登记一条流。
    func start() {
        // 一次屏幕只造一条：重复调用不换号、也不多一条流（视图重算会让这里被调多次）。
        guard stream == nil else { return }
        stream = makeStream()
    }

    /// 只重开这一条流 —— 流级动作，不动连接与别的流。
    ///
    /// 两个来由：用户点了「重试」，或者未定稿基线丢了、后续 chunk 接不上。同一个动作，
    /// 所以只有这一个入口 —— 分成两个方法只会让「哪一个才是真的重开」变成要读实现才知道的事。
    func retry() {
        stream?.restart()
    }

    /// 离开会话详情：注销这条流。连接留在原处（App 级）。
    func stop() {
        stream?.close()
        stream = nil
    }
}
