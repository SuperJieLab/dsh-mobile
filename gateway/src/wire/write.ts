/**
 * 两端共守的写载荷形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Rpc/Wire/RpcMessages.swift`）—— 改字段那边必须同改。
 *
 * 写载荷从严校验，与读路径不同：畸形决定被静默执行，等于凭猜测运行一条远程
 * 命令，因此每条畸形写都以 `invalid-request` 拒绝。
 *
 * 这里**只有形状与解析**。答应的结局词汇住在 `ports/write.ts`（装配边界），
 * 结论是否有地方翻译：**没有**。`allowed-once` / `rejected` / `{answers:[…]}` 是
 * 上游的词汇，客户端直接发、网关原样转 —— 一张映射表就是第二份词汇（F3 第 3 期删掉了
 * 那张 `allow`→`allowed-once` 的表）。
 *
 * `answerId` 已经退场（F3 第 3 期）：幂等由上游 waterfall 的一次性消费承担 ——  // terms-ok: 说明已退场的键
 * 对已结算的事件再答一次是**幂等 no-op**，不是错误。客户端不再需要铸键。
 */
import { isPlainObject, nonEmptyString, requestContainerOf } from './fields.ts'

/** 上游应答里的一种结局。三种都收，客户端目前只发 `result`。 */
export type RemoteEventOutcome =
  | { readonly kind: 'next' }
  | { readonly kind: 'result'; readonly value?: unknown }
  | { readonly kind: 'rejected'; readonly error: RemoteEventRejection }

/** `rejected` 携带的错误。`code` 与 `details` 原样透传，不解释。 */
export interface RemoteEventRejection {
  readonly name: string
  readonly message: string
  readonly code?: string
  readonly details?: unknown
}

/**
 * 校验通过的 `$events/result` 消息。
 *
 * `eventId` 指向上游 `waterfall` 帧上的那一个；`clientId` 是**手机在网关这条流上**
 * 的登记键（`ready` 帧发的那个），不是上游的身份 —— 那个换算只发生在
 * `upstream/write.ts`，协议层不碰。
 */
export interface RemoteEventResultMessage {
  readonly clientId: string
  readonly eventId: string
  readonly outcome: RemoteEventOutcome
}


function rejectionOf(raw: unknown): RemoteEventRejection | undefined {
  if (!isPlainObject(raw)) return undefined
  const name = nonEmptyString(raw.name)
  const message = nonEmptyString(raw.message)
  if (name === undefined || message === undefined) return undefined
  const code = raw.code === undefined ? undefined : nonEmptyString(raw.code)
  if (raw.code !== undefined && code === undefined) return undefined
  return {
    name,
    message,
    ...(code === undefined ? {} : { code }),
    ...(raw.details === undefined ? {} : { details: raw.details }),
  }
}

/** 把 `outcome` 收成三支之一；不认识的 kind 或残缺的形状一律无。 */
function outcomeOf(raw: unknown): RemoteEventOutcome | undefined {
  if (!isPlainObject(raw)) return undefined
  switch (raw.kind) {
    case 'next':
      return { kind: 'next' }
    case 'result':
      // `value` 缺席是合法的（结算成 `undefined`）；显式给 `undefined` 不是。
      // 后者只在直接调用本函数时构造得出来，但两者在线上会变成同一个形状 ——
      // 于是「带了 value」这件事静默消失。
      if ('value' in raw && raw.value === undefined) return undefined
      return 'value' in raw ? { kind: 'result', value: raw.value } : { kind: 'result' }
    case 'rejected': {
      const error = rejectionOf(raw.error)
      return error === undefined ? undefined : { kind: 'rejected', error }
    }
    default:
      return undefined
  }
}

/**
 * 解析并校验一条 `$events/result` 载荷，完全不像应答时返回 `undefined`。
 * 刻意从严 —— 见模块注释。
 */
export function remoteEventResultOf(message: Record<string, unknown>): RemoteEventResultMessage | undefined {
  const clientId = nonEmptyString(message.clientId)
  const eventId = nonEmptyString(message.eventId)
  if (clientId === undefined || eventId === undefined) return undefined
  const outcome = outcomeOf(message.outcome)
  if (outcome === undefined) return undefined
  return { clientId, eventId, outcome }
}

/** prompt 里的一段内容。本期只有文本 —— 附件在 spec 范围外。 */
export interface PromptTextPart {
  readonly type: 'text'
  readonly text: string
}

/**
 * 校验通过的 `session/prompt` 消息 —— 上游 `SessionPromptRequest` 的形。
 *
 * `requestId` 是客户端铸的**关联 id**（不是幂等键）：宿主把它写进持久消息的
 * `source.rpcId`，客户端据此把乐观插入的那一行与落定的那一行对上。
 */
export interface SessionPromptMessage {
  readonly requestId: string
  readonly sessionId: string
  readonly mode: 'queue' | 'steer'
  readonly content: readonly PromptTextPart[]
  readonly clientTimeZone?: string
}

function textPartOf(raw: unknown): PromptTextPart | undefined {
  if (!isPlainObject(raw)) return undefined
  if (raw.type !== 'text') return undefined
  if (typeof raw.text !== 'string') return undefined
  return { type: 'text', text: raw.text }
}

/**
 * 解析并校验一条 `session/prompt` 载荷（**含宿主的 `request` 容器**）。
 *
 * 五个键逐格校验，容器缺席即拒。`content` 至少一段非空白文本 —— 与上游
 * `hasPromptContent` 同一条底线；附件不在本期范围内，所以只收 `type:"text"`。
 */
export function sessionPromptOf(args: Record<string, unknown>): SessionPromptMessage | undefined {
  const request = requestContainerOf(args)
  if (request === undefined) return undefined

  const requestId = nonEmptyString(request.requestId)
  const sessionId = nonEmptyString(request.sessionId)
  const mode = request.mode === 'queue' || request.mode === 'steer' ? request.mode : undefined
  if (requestId === undefined || sessionId === undefined || mode === undefined) return undefined

  if (!Array.isArray(request.content) || request.content.length === 0) return undefined
  const content: PromptTextPart[] = []
  let hasText = false
  for (const raw of request.content) {
    const part = textPartOf(raw)
    if (part === undefined) return undefined
    if (part.text.trim() !== '') hasText = true
    content.push(part)
  }
  if (!hasText) return undefined

  let clientTimeZone: string | undefined
  if ('clientTimeZone' in request) {
    clientTimeZone = nonEmptyString(request.clientTimeZone)
    if (clientTimeZone === undefined) return undefined
  }

  return {
    requestId,
    sessionId,
    mode,
    content,
    ...(clientTimeZone === undefined ? {} : { clientTimeZone }),
  }
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
