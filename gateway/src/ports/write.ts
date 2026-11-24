/**
 * 装配边界：写路径所依赖的能力，由宿主适配层实现。
 *
 * 接口与「交付结局」一起住这里：结局是**网关这一层失败的说法**，不是线上形状 ——
 * 手机端只看到 `ok` 或协议错误码，从来见不到 `delivered` / `undelivered`。
 *
 * 上游的结局词汇（`allowed-once` / `rejected` / `{answers:[…]}`）**不经过这里**：
 * 它在 `wire/write.ts` 的形状里，网关原样转发，没有映射表。
 */

import type { RemoteEventResultMessage, SessionPromptMessage } from '../wire/write.ts'

/**
 * 一次应答交付的两个结局。
 *
 * 没有「不在暂存表里」这一支：上游对已结算的 `eventId` 是幂等 no-op 并返回成功，
 * 网关不替它下结论。
 */
export type AnswerDelivery = 'delivered' | 'undelivered'

/** 两条写路径所依赖的数据源 —— 写契约的唯一依赖。 */
export interface WritePort {
  /**
   * 把一条 `$events/result` 投递给上游。
   *
   * `delivered` = 上游收下了（结算或幂等 no-op）；`undelivered` = 上游拒了，或网关此刻
   * 没有上游身份（它认不出这条应答属于谁）。后者该让客户端看到一个失败，而不是 `ok`。
   */
  answerEvent(result: RemoteEventResultMessage): Promise<AnswerDelivery>
  /**
   * 把一条 prompt 收进会话的 agent 收件箱；会话不存在时报告之。
   * 其余上游失败归调用方的 `internal-error`。
   */
  promptSession(prompt: SessionPromptMessage): Promise<'accepted' | 'unknown-session'>
  /**
   * 建一个空会话，返回它的 id。
   *
   * **目录由 `workspaceId` 决定**：指定了就落在那个工作空间的目录里（宿主把它
   * `attachSession` 进那个工作空间），没指定就由宿主用自己的当前目录 —— 后者是
   * 「不带工作空间建会话」的那条路，不能删。
   *
   * 同目录已有空会话时宿主会复用它。那条规则**不是本端口的承诺**：调用方不得据此
   * 推断「调两次必有两个会话」，也不得推断「必是同一个」。
   */
  createSession(workspaceId?: string): Promise<string>
}
