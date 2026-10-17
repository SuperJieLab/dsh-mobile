/**
 * 装配边界：两条写 op 所依赖的能力，由宿主适配层实现。
 *
 * 接口与「结局词汇」一起住这里：结局是**上游失败的说法**，不是线上形状 ——
 * 手机端只看到 `ok` 或协议错误码，从来看不见 `delivered` / `undelivered`。
 */

import type { ApprovalAnswerMessage, SessionPromptMessage } from '../wire/write.ts'

/**
 * 一条 approval 应答的三个结局，见 {@link WritePort.answerApproval}。
 * 具名是为了**只此一处定义** —— 这组字面量曾被手抄在四处，其中 `ReplayTable`
 * 那处漏了 `undelivered`：重复本身会漂。
 */
export type ApprovalOutcome = 'delivered' | 'unknown-approval' | 'undelivered'

/** 两条写 op 所依赖的数据源 —— 写契约的唯一依赖。 */
export interface WritePort {
  /**
   * 把一条回答投递给挂起的 approval。
   *
   * 三个结局：`delivered` = 上游收下了（它随后自己结算并记审计）；`unknown-approval` =
   * 没有挂起 approval 对应该 id（已消费 / 已取消 / 从未问过）；**`undelivered` = 上游
   * 拒了这条回答**（身份、准入或形状不合适）—— 此时问题仍挂在上游等着，客户端该看到
   * 一个失败而不是 `ok`。
   */
  answerApproval(answer: ApprovalAnswerMessage): Promise<ApprovalOutcome>
  /**
   * 把一条 prompt 收进会话的 agent 收件箱；会话不存在时报告之。
   * 其余上游失败归调用方的 `internal-error`。
   */
  promptSession(prompt: SessionPromptMessage): Promise<'accepted' | 'unknown-session'>
}
