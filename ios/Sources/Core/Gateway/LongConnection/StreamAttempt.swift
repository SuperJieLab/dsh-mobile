import Foundation

/**
 * 「这一次尝试」的令牌：哪一代连接、哪一条传输。
 * 它住父级而不是任一层：**两层共守** —— WebSocket 层生成它（`attempt` 是它的能力），
 * 流层按它判「这份答复是不是给出去了的那个连接」。
 * 两个字段缺一不可：单看代次，同代之内传输也可能已被替换（连接是先关后建）。
 */
struct StreamAttempt: Equatable {
    let generation: Int
    let connection: AnyObject

    static func == (lhs: StreamAttempt, rhs: StreamAttempt) -> Bool {
        lhs.generation == rhs.generation && lhs.connection === rhs.connection
    }
}
