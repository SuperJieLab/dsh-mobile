/**
 * 写契约：两条写 op 的解析与重放簿记 ——
 * M5 §四。写载荷从严校验，与读路径
 * 不同：畸形决定被静默执行，等于凭猜测运行一条远程命令，因此每条畸形写
 * 都以 `invalid-request` 拒绝。
 *
 * 重放表让重试安全：回复丢失后的重发会再次得到第一次的结果。
 * 重启即清空，无害 —— 日志中的 `approval/decided` 审计才是客户端对账的
 * 真相。
 */

// 写载荷的形状与解析已搬到 `wire/`（两端共守）；这里 import 再用并重导出。
import type { ApprovalAnswerMessage, SessionPromptMessage } from '../wire/write.ts'
export { approvalAnswerOf, sessionPromptOf } from '../wire/write.ts'
export type { ApprovalAnswerMessage, SessionPromptMessage } from '../wire/write.ts'

// 端口与结局词汇已搬到装配边界 `ports/write.ts`；这里重导出，重放表留在这。
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
