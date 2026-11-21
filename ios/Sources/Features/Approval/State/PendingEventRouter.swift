/**
 * 一个 `waterfall` 属于哪个域 —— **分派判定只在这里**。
 *
 * 为什么是纯函数而不是写在 sink 里：`$events` 只给一张 `waterfallListeners`，两类挂起项
 * 混在同一条通道上。判定写进订阅闭包的话，它就与「注册了几个听众」绑在一起，测不到、
 * 也数不清有几份。抽成值之后，加第三类时改的是一处 `case`。
 */
import Foundation

enum PendingEventRouter {

    /// 两类待答调用。与网关的 `PENDING_EVENTS` 是同一组名字，两端各有一份是因为一个是
    /// TS、一个是 Swift —— 共守样本钉住形状，名字这一格没有编译期通道。
    enum Kind: Equatable {
        /// 工具审批。
        case approval
        /// 上游向人提问。
        case question
    }

    /// 不认识的 `event` 返回 `nil`：不猜它属于哪个域。要不要留痕由调用方决定。
    static func kind(of payload: JSONValue) -> Kind? {
        guard let event = payload["event"]?.string else { return nil }
        switch event {
        case "approval/request": return .approval
        case "user-questions/request": return .question
        default: return nil
        }
    }
}
