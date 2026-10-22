import Foundation

/**
 * 没有流编号的帧的收货人。
 *
 * 审批帧不带编号 —— 它不属于任何一条流，属于这条连接。这个协议把「收货人」与「连接」
 * 分成两件事：连接层只管把帧送到这里，谁收、收到之后怎么判，都在实现方。
 *
 * 它是 `AnyObject`：收货人与连接同寿（根部创建、活到 App 结束），值类型会让「谁在收」
 * 变成一份副本，「清空时清的是哪一张表」就说不清了。
 */
@MainActor
protocol UnscopedFrameSink: AnyObject {
    func accept(_ frame: MuxServerEnvelope)
}

/**
 * 连接层对「不属于流的帧」与「换代次」的两件对外能力。
 *
 * 收成协议而不是给一个具体的 `FollowClient`：消费方要能脱离 socket 接线、被断言 ——
 * 这两件事坏了都不编译失败（症状是「审批永不显示」或「重连后卡片不回来」）。
 */
@MainActor
protocol UnscopedFrameFeed: AnyObject {
    /// 无编号帧的收货人。
    var unscopedSink: (any UnscopedFrameSink)? { get set }
    /// 新连接代次开始。
    func onConnectionGeneration(_ handler: @escaping (Int) -> Void)
}
