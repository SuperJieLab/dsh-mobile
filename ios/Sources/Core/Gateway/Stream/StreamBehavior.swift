/**
 * 一条流的两段自定义 —— 流层只问这两件事，其余全归自己。
 *
 * 「组合」在这里是具体的：业务把自己那套判读装进一个类型交给 `StreamMux.makeStream`，
 * 拿回来一个流对象。流层不知道 op 名、不知道帧类型有哪几种取值、不知道哪个错误码是终态；
 * 它只把帧交进去，照返回的两句话办（建成没有、下一步怎么办）。
 *
 * 两段自定义**只在造流那一刻绑定一次**：换号重开用的是同一个对象，`build` 会拿到新编号再调
 * 一次（文本必须与编号一致），`handle` 每帧都调。
 *
 * `AnyObject` 与强持有：业务对象与它那条流同生共死。流对象强引着它，于是
 * 「业务 → 流对象 → 业务」是一个环 —— **只有 `close()` 能解开**，与流表持有订阅者的
 * 现有语义一致。业务侧因此不能靠 dealloc 收尾，必须显式关流。
 */
import Foundation

@MainActor
protocol StreamBehavior: AnyObject {

    /// 日志里认人的标识（会话 id、`connection-events` 之类）。流层不解释它。
    var label: String { get }

    /// 凭刚造好的编号拼出开流文本。
    ///
    /// 抛错意味着形状自己坏了（例如 encoder 拒绝某个字段）：这一次开流放弃，不换号 ——
    /// 换了号却不发帧，那条流就永远等不到开口帧。
    func build(_ id: StreamId) throws -> String

    /// 收到一帧：外壳加原始字节。返回值决定这条流下一步怎么办。
    ///
    /// 原始字节一并交出，是因为 typed 载荷（打开帧、事件、占用）要就地直解一次；
    /// 经 `JSONValue` 往返的每一步都可能悄悄改掉一次取值。
    func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply
}
