/**
 * 写通道的服务端部分：幂等重放与结论词汇映射。
 *
 * 载荷形状与解析在 `wire/write.ts`（两端共守，手机端同改）；端口与结局词汇在
 * `ports/write.ts`（装配边界）。这里只剩服务端自己才需要的那两件 —— 让重试安全
 * 的重放表，以及把客户端的两键选择翻成上游的结论词。
 *
 * 写载荷从严校验是**那边**的规则：畸形决定被静默执行，等于凭猜测运行一条远程
 * 命令，所以每条畸形写都以 `invalid-request` 拒绝。
 */

export { approvalAnswerOf, sessionPromptOf } from '../wire/write.ts'
export type { ApprovalAnswerMessage, SessionPromptMessage } from '../wire/write.ts'
export type { ApprovalOutcome, WritePort } from '../ports/write.ts'

/**
 * 记住每个幂等键的第一次结果，此后永远重放它：`produce` 每键至多运行一次，
 * 其副作用因此只发生一次。
 */
export class ReplayTable<V> {
  readonly #entries = new Map<string, V>()

  remember(key: string, produce: () => V): { value: V; fresh: boolean } {
    const existing = this.#entries.get(key)
    if (existing !== undefined) return { value: existing, fresh: false }
    const value = produce()
    this.#entries.set(key, value)
    return { value, fresh: true }
  }
}

/** 把客户端的两键词汇映射到上游的结论词汇。 */
export function outcomeOfDecision(decision: 'allow' | 'deny'): 'allowed-once' | 'rejected' {
  return decision === 'allow' ? 'allowed-once' : 'rejected'
}
