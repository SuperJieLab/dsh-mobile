/**
 * 两端共守的写载荷形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Contract/GatewayProtocol.swift`）—— 改字段那边必须同改。
 *
 * 写载荷从严校验，与读路径不同：畸形决定被静默执行，等于凭猜测运行一条远程
 * 命令，因此每条畸形写都以 `invalid-request` 拒绝。
 *
 * 这里**只有形状与解析**。答应的结局词汇住在 `ports/write.ts`（装配边界），
 * 结论词映射住在 `upstream/write.ts`（上游的词汇）。
 *
 * `answerId` 的幂等语义是**协议承诺**：同键重试必须得到第一次的结论。实现那张
 * 重放表在宿主机侧（`upstream/write.ts` 的 `ReplayTable`），手机端看不见表，
 * 但可以依赖它的效果。
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

/** 非空字符串，否则无。 */
function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}
