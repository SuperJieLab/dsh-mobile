/**
 * 一屏的输入侧：持久窗口的镜像，以及读它所需的最小口径。
 *
 * 消费者是 `SessionSync`（读窗口事实、发起翻页、喂食引擎）与它的用例。`SessionMirror`
 * 本身不外露 —— 交出去等于把它的成员重新散给调用方，而「改它的接口要跟几处」正是这一层要收的东西。
 *
 * 窗口事实分三组：读数是值，动作要么成功要么不动，翻页的 `beginRequest` / `abandonRequest`
 * 与 `prepend` 必须成对 —— 请求权在途而窗口已变的中间态对外不可见。
 */
import Foundation

@MainActor
final class SessionInput {

    /// 本地权威副本。位置只由几个合并方法推进，改它的方法都要求一份服务端回应。
    private var window = SessionMirror()

    // MARK: - 读数

    /// 窗口之前还有没有更早的记录。
    var hasMore: Bool { window.hasMore }
    /// 当前窗口首条事件的 `seq`。
    var windowStart: Int { window.windowStart }
    /// 打开那一刻日志覆盖到的最后一个 `seq`（含端）。翻页时原样带回，钉住切点。
    var throughSeq: Int { window.throughSeq }
    /// 下一个期望的 `seq` —— 已有内容的末尾（不含）。
    var frontier: Int { window.frontier }
    /// 还没有任何内容 —— 冷启动、或刚被重置。
    var isEmpty: Bool { window.isEmpty }
    /// 窗口全量。只服务日志计数与整段重建这两类需要看全的场景，常态喂食走 `takeFeed`。
    var records: [SessionEvent] { window.events }

    /// 取走这一批新增的持久事件。返回空表示「没有新东西」。
    func takeFeed() -> [SessionEvent] { window.takeFeed() }

    // MARK: - 窗口动作

    /// 打开或重连：新的窗口与本地重对齐，本地更早的部分按起点位置保留或替换。
    func realign(with window: SessionWindow) -> Verdict {
        self.window.realign(with: window)
    }

    /// 往回翻：把更早的一段前插。只接受紧邻的一页。
    func prepend(_ page: SessionWindow) -> Verdict { window.prepend(page) }

    /// 并进一条实时事件。重复丢掉、跳号判缺口。
    func append(_ event: SessionEvent) -> Verdict { window.append(event) }

    /// 把一批记录重新排进下一批。
    ///
    /// 扣下的定稿被作废之后要靠它回来：那一批已经被取走过，没有这一步它们就永久停在窗口里。
    func requeue(_ events: [SessionEvent]) { window.requeue(events) }

    /// 丢弃位置与视图 —— 调用方在收到「位置不作数」之后才调。
    func reset() { window.reset() }

    // MARK: - 翻页

    /// 发起请求的门：同一会话同时只允许一个在途。
    func beginRequest() -> Bool { window.beginRequest() }

    /// 请求失败：放掉在途标记，视图与位置一律不动。
    func abandonRequest() { window.abandonRequest() }
}
