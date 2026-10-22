import Foundation

/**
 * 一屏对常驻连接能做的全部动作 —— **只有流级**。
 *
 * 这个协议的存在是为了让一类错法写不出来：一条流被拒时去关整条连接。那是连接级动作，
 * 会把同一条连接上的另一条流一起拽断；而屏幕这一侧看到的只是「另一条流没了」。
 * 需要连接级动作的只有根部（回前台、组网就绪），它持有的是具体类型。
 *
 * 连接阶段**不**在这个协议上：读它要能订阅（`$phase`），而那只有具体类型给得出；
 * 屏幕这一侧因此两份引用（`streams` 只做、`link` 只读），合成一个就丢掉了后一半。
 */
@MainActor
protocol SessionStreamHandle: AnyObject {

    /// 登记一条流（会话详情进屏）。
    func open(_ subscription: FollowClient.Subscription)

    /// 注销自己那一条（离屏）。晚到的注销不碰别人。
    func close(owner: AnyObject)

    /// 这一条流换号重开：基线丢了、或用户按了「重试」。**连接与别的流不动。**
    func reopen(owner: AnyObject)
}
