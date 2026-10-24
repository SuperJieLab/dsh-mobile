import Foundation

/**
 * 「这一次尝试」的令牌：哪一代连接、哪一条传输。
 *
 * 它住父级而不是任一层：**两层共守** —— WebSocket 层生成它（`attempt` 是它的能力），
 * 流层拿它做相等比较（「还是不是这一次尝试」）。放进任一层，另一层引用它就是跨层依赖。
 *
 * 两个字段缺一不可：单看代次，同代之内传输也可能已被替换（连接是先关后建），
 * 那时一个被取代的回调若还被算数，就会把刚建好的连接掐掉、再排一次重连。
 */
struct StreamAttempt: Equatable {
    let generation: Int
    let connection: AnyObject

    static func == (lhs: StreamAttempt, rhs: StreamAttempt) -> Bool {
        lhs.generation == rhs.generation && lhs.connection === rhs.connection
    }
}
