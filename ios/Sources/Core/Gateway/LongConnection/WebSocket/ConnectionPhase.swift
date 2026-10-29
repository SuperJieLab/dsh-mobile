/**
 * 一条 socket 的连接阶段 —— 界面读它画网络格与连接详情。
 *
 * 含义是「这条连接走到哪一步」，与登记了几条流无关。顶层类型而不是嵌在传输层里：界面写
 * `WebSocketConnection.Phase` 就等于持有传输层。与 `MeshPhase` 不同：那说隧道，这说 socket。
 */
enum ConnectionPhase: Equatable {
    /// 没有连接，也没有排定的重试。
    case idle
    /// **在等组网**：本层连不上不是它的错，而是外面还没有可连的地址。
    /// 与 `.waiting` 的分界是**谁该重试**：`.waiting` 说「等会儿我自己再来」，
    /// 这里说「该别人先动」。
    case awaitingMesh
    /// 正在握手。
    case connecting
    /// 这条连接已经通了：本代收到过至少一条可解析的帧。
    case ready
    /// 等一轮退避后重连；携带毫秒数，界面可以如实显示。
    case waiting(ms: Int)
}
