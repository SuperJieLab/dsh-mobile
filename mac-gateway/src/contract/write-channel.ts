/**
 * 写契约：两条写 op 的解析与重放簿记 ——
 * dev/plans/M5-remote-intervention.md §四。写载荷从严校验，与读路径
 * 不同：畸形决定被静默执行，等于凭猜测运行一条远程命令，因此每条畸形写
 * 都以 `invalid-request` 拒绝。
 *
 * 重放表让重试安全：回复丢失后的重发会再次得到第一次的结果。
 * 重启即清空，无害 —— 日志中的 `approval/decided` 审计才是客户端对账的
 * 真相。
 */

/** 校验通过的 `approval-answer` 消息。 */
export interface ApprovalAnswerMessage {
  /**
   * 本回答针对的 `$events` waterfall 帧 `eventId` —— 手机看到的
   * `approval-request` 帧所带的 id（投影出的请求没有审计 id，这是唯一的
   * 端到端地址）。
   */
  eventId: string
  /** 客户端的选择；投递时映射到上游的结论词汇。 */
  decision: 'allow' | 'deny'
  /** 客户端铸造的幂等键。同键重试重放第一次的结果。 */
  answerId: string
}

/**
 * 解析并校验一条 `approval-answer` 载荷，完全不像回答时返回 `undefined`。
 * 刻意从严 —— 见模块注释。
 */
export function approvalAnswerOf(message: Record<string, unknown>): ApprovalAnswerMessage | undefined {
  const eventId = nonEmptyString(message.eventId)
  const decision = message.decision === 'allow' || message.decision === 'deny' ? message.decision : undefined
  const answerId = nonEmptyString(message.answerId)
  if (eventId === undefined || decision === undefined || answerId === undefined) return undefined
  return { eventId, decision, answerId }
}

/** 校验通过的 `session-prompt` 消息。 */
export interface SessionPromptMessage {
  /** 目标会话。 */
  sessionId: string
  /** prompt 文本；空或纯空白无法成为上游的 prompt。 */
  text: string
  /** 客户端铸造的幂等键，作为 prompt 的 `requestId` 传给上游。 */
  promptId: string
}

/**
 * 解析并校验一条 `session-prompt` 载荷，不像时返回 `undefined`。`sessionId`
 * 不在此校验：读路径已把畸形 id 映射到 `unknown-session`，写路径沿用
 * 该约定。
 */
export function sessionPromptOf(message: Record<string, unknown>): SessionPromptMessage | undefined {
  const sessionId = nonEmptyString(message.sessionId)
  const text = typeof message.text === 'string' ? message.text : undefined
  const promptId = nonEmptyString(message.promptId)
  if (sessionId === undefined || promptId === undefined || text === undefined || text.trim() === '') {
    return undefined
  }
  return { sessionId, text, promptId }
}

/** 两条写 op 所依赖的数据源 —— 写契约的唯一依赖。 */
export interface WritePort {
  /**
   * 把一条回答投递给挂起的 approval；没有挂起 approval 对应该 id
   * （已消费、已取消、或从未问过）时报告之。
   */
  answerApproval(answer: ApprovalAnswerMessage): Promise<'delivered' | 'unknown-approval'>
  /**
   * 把一条 prompt 收进会话的 agent 收件箱；会话不存在时报告之。
   * 其余上游失败归调用方的 `internal-error`。
   */
  promptSession(prompt: SessionPromptMessage): Promise<'accepted' | 'unknown-session'>
}

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

/** 非空字符串，否则无。 */
function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}
