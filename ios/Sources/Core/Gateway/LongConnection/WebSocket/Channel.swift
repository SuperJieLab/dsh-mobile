/**
 * 一条 WebSocket 连接对外提供什么：三个能力、两个事实。
 *
 * 公开面由提供方定 —— 能力是「发一段文本 / 要一条连接 / 现在是哪一代」，事实是
 * 「不要连接了 / 换了一代」。签名里没有一个「流」字：连接不知道自己身上挂着什么，
 * 也就不该用别人的词汇命名自己的成员。
 *
 * 它住在本层目录里：打开 `WebSocket/` 就该看到这一层提供什么。消费方引用它是引用接口，
 * 不是引用实现 —— 所以「流层引用它」不构成跨层依赖。
 */
@MainActor
protocol Channel: AnyObject {

    /// 发一段已经编好的文本。没有连接时静默（一个字节都不记）。
    func send(_ text: String)

    /// 现在就要一条连接：取消排着的那一拍退避，立刻建。不 active 时自己空转。
    func ensureConnected()

    /// 当前这一代的令牌；`nil` = 手上没有 socket。
    var attempt: StreamAttempt? { get }

    /// 不要连接了（App 收尾）。订阅方据此清掉不再有效的状态。
    var onStopped: (() -> Void)? { get set }

    /// 新一代连接开始了。订阅方据此把「绑在旧一代上」的东西换新号。
    var onGenerationChange: (() -> Void)? { get set }
}
