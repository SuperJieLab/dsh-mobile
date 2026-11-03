/**
 * 会话状态行 —— 「哪一步、哪一类原因」的唯一持有者。
 *
 * 它被三族动作写：读侧编排（取窗口 / 追新增 / 往回翻）、写侧（发消息 / 命令 / 选模型）、
 * 流开关（订阅被拒）。三族的变化原因各不相同，但**屏幕上只有一条状态行** —— 所以它不住在
 * 任何一个编排里，而是被它们共享。句子住 `Display/SyncText.swift`。
 *
 * 做成持有者而不是三份拷贝：三处各写一份 `status` 时，「现在到底在同步还是在发送」
 * 就没有唯一的答案，而那是用户唯一能看见的东西。
 */
import Foundation

@MainActor
@Observable
final class SessionStatus {

    /// 状态行要说的事 —— 只报「哪一步 + 哪一类原因」。
    enum Value {
        case idle
        case syncing
        case done(added: Int, recovered: Bool)
        case failed(step: Step, cause: Cause)
    }

    /// 失败发生在哪一步 —— 每步各有一句说法。
    enum Step {
        case opening
        case paging
        case syncing
        case sending
        case executing
        case selecting
        case streaming
    }

    /// 失败属于哪一类 —— 按「谁说的」分，不按 `RpcClientError` 的 case 分。
    enum Cause {
        /// 镜像只说「没成」：取窗口 / 追新增 / 往回翻的传输失败都没有错误对象。
        case transport
        /// 服务端按信封拒绝，但镜像只留了协议码。
        case refusal(code: String)
        /// 编排自己执行的重置撞上了缺口，连着两次。
        case resetLoop(ResetReason)
        /// 抛出来的错误原样带过去：编排查不出它属于哪一类，也不需要查 —— 显示层会解释。
        case thrown(any Error)
    }

    private(set) var value: Value = .idle

    func set(_ value: Value) {
        self.value = value
    }
}
