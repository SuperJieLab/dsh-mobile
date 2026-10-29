/**
 * 一条流的两段自定义 —— 流层只问这两件事：这一帧建成没有、这条流接下来怎么办。
 *
 * 流层不知道 op 名、不知道帧类型有哪几种取值、不知道哪个错误码是终态。两段只在造流那一刻
 * 绑定一次：`build` 在换号重开时再调（文本必须与编号一致），`handle` 每帧都调。
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
