import Foundation

/**
 * 一屏对常驻连接能做的全部动作 —— **只有流级**。
 *
 * 这个协议的存在是为了让一类错法写不出来：一条流被拒时去关整条连接。那是连接级动作，
 * 会把同一条连接上的另一条流一起拽断；而屏幕这一侧看到的只是「另一条流没了」。
 * 需要连接级动作的只有根部（回前台、组网就绪），它持有的是具体类型。
 *
 * 连接阶段在这里是**只读**的：连接详情要显示「现在连到哪一步」，那是读，不是做。
 */
@MainActor
protocol SessionStreamHandle: AnyObject {

    /// 连接阶段 —— 功能条的网络格与连接详情的数据源。
    var phase: FollowClient.Phase { get }

    /// 登记一条流（会话详情进屏）。
    func open(_ subscription: FollowClient.Subscription)

    /// 注销自己那一条（离屏）。晚到的注销不碰别人。
    func close(owner: AnyObject)

    /// 这一条流换号重开：基线丢了、或用户按了「重试」。**连接与别的流不动。**
    func reopen(owner: AnyObject)
}
