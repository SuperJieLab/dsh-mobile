/**
 * 两端共守的写载荷形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift`）—— 改字段那边必须同改。
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
import { nonEmptyString, requestContainerOf } from './fields.ts'

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
  /**
   * 这条审批是**在哪条流上看到的** —— 网关据此判「这次应答是不是这条流的主人在答」。
   *
   * 必填而不是可选：缺一格就无法归属，而「缺了当没带」会让归属判定静默失效 ——
   * 宁可整条 `invalid-request`，也不要一条没有主人的应答。
   */
  clientId: string
}

/**
 * 解析并校验一条 `approval-answer` 载荷，完全不像回答时返回 `undefined`。
 * 刻意从严 —— 见模块注释。
 */
export function approvalAnswerOf(message: Record<string, unknown>): ApprovalAnswerMessage | undefined {
  const eventId = nonEmptyString(message.eventId)
  const decision = message.decision === 'allow' || message.decision === 'deny' ? message.decision : undefined
  const answerId = nonEmptyString(message.answerId)
  const clientId = nonEmptyString(message.clientId)
  if (eventId === undefined || decision === undefined || answerId === undefined || clientId === undefined) {
    return undefined
  }
  return { eventId, decision, answerId, clientId }
}

/** 一个问题的一道答案。`selected` 可为空数组（只填了自定义文本）。 */
export interface QuestionAnswerItem {
  /** 对应 `question.id`。 */
  readonly id: string
  /** 选中的选项 label；多选时可多项。 */
  readonly selected: readonly string[]
  /** 「其它」的自由文本，可与选项并存。 */
  readonly custom?: string
}

/**
 * 校验通过的问题应答消息。
 *
 * 与审批的载荷**不共用一格**：`decision` 在问题场景没有对应物，`answers` 在审批场景也没有。
 * 塞进一个载荷就得让校验为另一套放行，那是两处判断、一处漏洞。
 */
export interface QuestionAnswerMessage {
  /** 本回答针对的 `$events` waterfall 帧 `eventId`。 */
  readonly eventId: string
  /** 一张卡的整批答案 —— 键是卡，不是单个问题。 */
  readonly answers: readonly QuestionAnswerItem[]
  /** 客户端铸造的幂等键。同键重试重放第一次的结果。 */
  readonly answerId: string
  /** 这条问题是在哪条流上看到的 —— 归属判定用。 */
  readonly clientId: string
}

function questionAnswerItemOf(raw: unknown): QuestionAnswerItem | undefined {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return undefined
  const record = raw as Record<string, unknown>
  const id = nonEmptyString(record.id)
  if (id === undefined) return undefined
  if (!Array.isArray(record.selected)) return undefined
  const selected: string[] = []
  for (const entry of record.selected) {
    if (typeof entry !== 'string') return undefined
    // 空白串不是 label —— 与 `custom` 用同一条规则（那里也 trim），两处宽严不一会让
    // 「只填了空格」在两个字段上一个算答过、一个不算。
    if (entry.trim() === '') return undefined
    selected.push(entry)
  }
  let custom: string | undefined
  if ('custom' in record) {
    if (typeof record.custom !== 'string') return undefined
    custom = record.custom.trim() === '' ? undefined : record.custom
  }
  // 一项既没选任何选项、也没填自定义文本 —— 它不是一次作答。
  if (selected.length === 0 && custom === undefined) return undefined
  return custom === undefined ? { id, selected } : { id, selected, custom }
}

/**
 * 解析并校验一条 `question-answer` 载荷，完全不像回答时返回 `undefined`。
 *
 * 从严的理由与审批相同：畸形决定被静默执行等于凭猜测答了一个问题。**只判形状** ——
 * 「答案有没有覆盖卡上全部问题」需要卡的内容，那在中继那层判。
 */
export function questionAnswerOf(message: Record<string, unknown>): QuestionAnswerMessage | undefined {
  const eventId = nonEmptyString(message.eventId)
  const answerId = nonEmptyString(message.answerId)
  const clientId = nonEmptyString(message.clientId)
  if (eventId === undefined || answerId === undefined || clientId === undefined) return undefined
  if (!Array.isArray(message.answers) || message.answers.length === 0) return undefined

  const answers: QuestionAnswerItem[] = []
  for (const raw of message.answers) {
    const item = questionAnswerItemOf(raw)
    if (item === undefined) return undefined
    answers.push(item)
  }
  return { eventId, answers, answerId, clientId }
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


/**
 * `session-create` 的目标：交给宿主的默认目录、指定一个工作空间，或一条畸形载荷。
 *
 * 三态而不是 `string | undefined`：`undefined` 同时能读成「没带」与「带了但是空的」，
 * 而后者是畸形载荷，必须拒 —— 写路径从严（见模块注释）。
 */
export type SessionCreateTarget =
  | { kind: 'default' }
  | { kind: 'workspace'; workspaceId: string }
  | { kind: 'invalid' }

/**
 * 解析 `session-create` 的载荷（**含宿主的 `request` 容器**）。
 *
 * **缺省是合法的一种**：不带 `workspaceId` 就走宿主的当前目录 —— 那是这条 op 在本功能
 * 之前唯一的行为，老客户端仍在用。但**容器本身不能缺**：少一层是旧客户端，
 * 按畸形拒（它的 `workspaceId` 一格都没送到）。
 *
 * @param args - `payload.args`；宿主的形参是 `request`，所以容器键名也是它。
 */
export function sessionCreateTargetOf(args: Record<string, unknown>): SessionCreateTarget {
  const message = requestContainerOf(args)
  if (message === undefined) return { kind: 'invalid' }
  if (!('workspaceId' in message)) return { kind: 'default' }
  const workspaceId = nonEmptyString(message.workspaceId)
  return workspaceId === undefined ? { kind: 'invalid' } : { kind: 'workspace', workspaceId }
}
