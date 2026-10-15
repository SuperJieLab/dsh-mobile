/**
 * 协议契约：一条线上消息进，一条线上消息出。
 *
 * `handle` 是注入数据源的普通 async 函数：无 HTTP、无 socket、无 DSH 运行时、
 * 无会话存储。所有传输原样复用它 —— 协议是消息，不是 URL（dev/contract/protocol.md；
 * M0 §4.3 Step 3）。水位：两个边界
 * 均为半开。`since` 是客户端*下一个期望的 seq*（`0` = 「我什么都没有」）；
 * `asOfSeq` 是「已覆盖到、不含」，并作为 `since` 回传，因此永远不会漏取或
 * 重取。两种不重叠的读取：`snapshot` 自 cursor 前向，`page` 反向取一个
 * 用于打开的窗口。
 *
 * 应答上限：单条应答 ≤ `maxDeltaEvents` 条事件，软性再受 `maxDeltaBytes`
 * 约束；提前截停用 `hasMore` 说明。上限约束单条应答，从不是序列的累计
 * （M1 §3.3.2 决定 4）。
 */

import { describeError, isUnreadable } from './errors.ts'
import type { ModelPort, ModelSelection } from './model-selection.ts'
import { modelSelectRequestOf } from './model-selection.ts'
import {
  LogNotDenseError,
  CursorPastEndError,
  pageWindow,
  type PageWindow,
} from './window.ts'
import {
  approvalAnswerOf,
  sessionPromptOf,
  type WritePort,
} from './write-channel.ts'

/** 本构建唯一使用的协议版本。 */
export const PROTOCOL_VERSION = 2

/**
 * 线上的一条会话事件：DSH 事件对象原样，未知字段一并保留。协议承诺下列
 * 字段存在，不承诺排他，客户端必须容忍未知字段。
 */
export interface WireEvent {
  /** DSH 事件类型，如 `user/message`。 */
  type: string
  /** 会话内单调递增的序号，从 0 连续。 */
  seq: number
  /** Unix 纪元毫秒。 */
  time: number
  /** 不透明载荷；协议层从不解读它。 */
  data: unknown
  [extraField: string]: unknown
}

/**
 * 会话列表的一行 —— 列表路径承诺的字段 (v2)。每个字段都来自会话头或
 * 已保留的投影，因此列表是零 I/O：这里没有任何东西需要读日志
 * （dev/contract/protocol.md §4.1）。
 */
export interface SessionRow {
  /** 已存储的会话 id。 */
  id: string
  /**
   * 当前标题。会话没有标题、或投影不可用时都缺省 —— 缺标题是契约
   * 的一部分，不是故障。
   */
  title?: string
  /** 会话创建时间的 Unix 纪元毫秒。 */
  createdAt: number
  /**
   * 最后一次用户 prompt 的 Unix 纪元毫秒；没有时取创建时间。**不是**最新
   * 事件的时间（v1 曾那样承诺，逼出一次日志读）。
   */
  updatedAt: number
  /** 该会话当前是否有 agent 在运行。 */
  running: boolean
  /** 会话是否还没有任何 turn。是否展示由客户端决定。 */
  blank: boolean
  /**
   * 本会话是另一会话的子会话时为 `'subagent'`，否则缺省。随行是为了让
   * 客户端自己应用参考 UI 的可见性规则 —— 服务端陈述事实，画不画仍归
   * 客户端。
   */
  origin?: string
}

/** 一次读出的会话日志切片，以及它到达的水位。 */
export interface SessionSlice {
  /** 下一个期望的 seq —— 见上文的半开规则。 */
  asOfSeq: number
  /** `seq >= since` 的事件，按 seq 排序，至多请求的限额。 */
  events: readonly WireEvent[]
  /** 本切片之后日志是否还有事件。 */
  hasMore: boolean
  /**
   * 客户端的 cursor 指向一个不可能存在的位置：`since` 为正而日志为空。
   * 这是数据源唯一能证明的错误 cursor —— 越过水位的 `since` 会读成
   * 「已追平」（M1 §3.3.2 决定 5）。
   */
  staleCursor: boolean
  /**
   * 会话的模型基线：*下一个*请求将用的模型，读自宿主的
   * `modelSelection` 投影。未知时缺省 —— 客户端回退到目录默认值，
   * 绝不猜测。
   */
  model?: ModelSelection
}

/**
 * 协议层所依赖的数据源 —— 契约的唯一依赖；用 fake 让测试摆脱运行时、
 * 文件系统与网络。
 */
export interface SessionPort {
  /** 本进程可见的所有会话。顺序无意义。 */
  list(): Promise<readonly SessionRow[]>
  /**
   * 至多 `limit` 条 `seq >= since` 的事件；会话不存在时返回 `undefined`。
   * 切片自报是否还有剩余。
   */
  read(id: string, since: number, limit: number): Promise<SessionSlice | undefined>
  /**
   * 整条日志；会话不存在时返回 `undefined`。反向窗口需要日志末端，而存储
   * 读 API 只能自偏移处前向 —— 取整条日志是够到尾部的代价。列表路径不再
   * 付这个价（v2 读投影）；`page` 仍付。
   */
  readAll(id: string): Promise<readonly WireEvent[] | undefined>
}

/**
 * 一条 `snapshot` 应答可能有多大；只约束单条应答，从不是客户端的视图。
 */
export interface Limits {
  /** 单条应答至多携带的事件数。必须为正。 */
  maxDeltaEvents: number
  /** 单条应答 `events` 序列化尺寸的软上限。 */
  maxDeltaBytes: number
  /**
   * follow 打开那一帧的字节上界（R9 期1）。它与上面两个不同：**不经由本文件的
   * `handle`，而且是硬上限** —— 装不下就按轮边界收窄，连一轮都装不下则拒绝。
   * HTTP 路径的软上限允许首条事件独自超限放行（否则客户端无法前进），那条规则
   * 在这里等于必然断连，不能照搬。
   */
  maxOpeningBytes: number
}

/**
 * LAN 演示的上限：宽到很少生效，小到确实有界。`maxOpeningBytes` 取 4 MiB ——
 * 本机观测到的最大窗口（1.25 MB）的 3 倍余量，于是普通会话根本不进收窄路径。
 */
export const DEFAULT_LIMITS: Limits = { maxDeltaEvents: 500, maxDeltaBytes: 1_048_576, maxOpeningBytes: 4 * 1024 * 1024 }

/**
 * 调用方不指定时一条 `page` 返回的消息数；对照参考客户端的页大小。
 * 这是*窗口*，不是上限：这里没有 `hasMore` 循环。
 */
export const DEFAULT_PAGE_MESSAGES = 50

/** 拒绝。`code` 取 dev/contract/protocol.md §六 中的码之一。 */
export interface WireError {
  code: string
  message: string
}

/** 任一成功应答。额外字段按 op 而定。 */
export interface OkResponse {
  v: typeof PROTOCOL_VERSION
  ok: true
  [field: string]: unknown
}

/** 任一被拒的应答。 */
export interface ErrorResponse {
  v: typeof PROTOCOL_VERSION
  ok: false
  error: WireError
}

/** 一条应答，成功或被拒。 */
export type Response = OkResponse | ErrorResponse

/**
 * 应答一条消息。
 *
 * @param message - 解析后的 JSON 主体，构造上形状未知。
 * @param port - 数据源；所有读都经它。
 * @param now - `serverTime` 用的时钟，可注入以保测试确定性。
 * @param limits - 应答上限；无意义值回退到 {@link DEFAULT_LIMITS}，
 *   绝不产生客户端永远无法读完的应答。
 * @returns 应答信封。从不抛错：敌意或卡死的数据源会变成拒绝
 *   （「进程不得崩溃」是判定过的判据）。
 */
export async function handle(
  message: unknown,
  port: SessionPort,
  now: () => number = Date.now,
  limits: Limits = DEFAULT_LIMITS,
  write?: WritePort,
  model?: ModelPort,
): Promise<Response> {
  const envelope = asRecord(message)
  if (envelope === undefined || envelope.v !== PROTOCOL_VERSION) {
    return failure('unsupported-version', `expected an object with v: ${PROTOCOL_VERSION}`)
  }

  const op = envelope.op
  if (typeof op !== 'string') return failure('unknown-op', 'request has no op')

  try {
    switch (op) {
      case 'list-sessions':
        return await listSessions(port, now)
      case 'snapshot':
        return await snapshot(envelope, port, normalizeLimits(limits))
      case 'page':
        return await page(envelope, port)
      case 'model-catalog':
        // 读 op。仅只读测试装配会缺端口；生产必接线，
        // 此拒绝在生产不可达。
        if (model === undefined) return failure('internal-error', 'model channel not wired for "model-catalog"')
        return await modelCatalog(model)
      case 'model-select':
        // 写 op，与写通道的 op 同一纪律。
        if (model === undefined) return failure('internal-error', 'model channel not wired for "model-select"')
        return await modelSelect(envelope, model)
      case 'approval-answer':
      case 'session-prompt':
        // 写 op。仅只读测试装配会缺 `write`；生产必接线，
        // 此拒绝在生产不可达。
        if (write === undefined) return failure('internal-error', `write channel not wired for "${op}"`)
        return op === 'approval-answer'
          ? await approvalAnswer(envelope, write)
          : await sessionPrompt(envelope, write)
      default:
        return failure('unknown-op', `unsupported op "${op}"`)
    }
  } catch (error) {
    // 两种拒绝，客户端应对不同：本运行时不解读的日志是「无法展示的会话」，
    // 其余是我们的错。
    return isUnreadable(error)
      ? failure('unreadable-session', describeError(error))
      : failure('internal-error', describeError(error))
  }
}

/**
 * 投递一条 approval 应答。`ok` 意为*已投递给挂起的问题* —— 权威结论
 * 是客户端从流中对账的 `approval/decided` 审计事件。
 */
async function approvalAnswer(envelope: Record<string, unknown>, write: WritePort): Promise<Response> {
  const answer = approvalAnswerOf(envelope)
  if (answer === undefined) {
    return failure('invalid-request', 'approval-answer needs eventId, decision ("allow" | "deny"), and answerId')
  }
  const outcome = await write.answerApproval(answer)
  if (outcome === 'unknown-approval') {
    return failure('unknown-approval', `no pending approval answers to "${answer.eventId}" — already decided, cancelled, or never asked`)
  }
  if (outcome === 'undelivered') {
    // 上游拒了这条回答：问题仍挂在它那里等着，所以这里不能说 `ok`（`ok` 意为
    // 「已投递给挂起的问题」）。原因在上游的 code 里，网关日志已记。
    return failure('internal-error', `the gateway refused the answer for "${answer.eventId}" — see the gateway log for its code`)
  }
  return { v: PROTOCOL_VERSION, ok: true, eventId: answer.eventId }
}

/**
 * 收纳一条 prompt。`ok` 意为*已接受进收件箱* —— 回复本体经流到达。
 */
async function sessionPrompt(envelope: Record<string, unknown>, write: WritePort): Promise<Response> {
  const prompt = sessionPromptOf(envelope)
  if (prompt === undefined) {
    return failure('invalid-request', 'session-prompt needs sessionId, promptId, and non-whitespace text')
  }
  const outcome = await write.promptSession(prompt)
  if (outcome === 'unknown-session') {
    return failure('unknown-session', `no stored session "${prompt.sessionId}"`)
  }
  return { v: PROTOCOL_VERSION, ok: true, sessionId: prompt.sessionId }
}

/**
 * 安装一条会话级模型选择。`ok` 意为*已为下一个请求装好* —— 持久的
 * `model/selection` 事件经流到达客户端，展示对账的正是它。
 * 上游的拒绝保留自己的码：`session/model-unavailable` 说模型不可路由，
 * 与畸形请求是不同的补救。
 */
async function modelSelect(envelope: Record<string, unknown>, model: ModelPort): Promise<Response> {
  const request = modelSelectRequestOf(envelope)
  if (request === undefined) {
    return failure('invalid-request', 'model-select needs sessionId, provider, and model')
  }
  const outcome = await model.select(request)
  if (!outcome.ok) return failure(outcome.code, outcome.message)
  return { v: PROTOCOL_VERSION, ok: true, selected: { ...outcome.selected } }
}

/** 模型目录路径：宿主目录原样，去掉客户端用不上的字段。 */
async function modelCatalog(model: ModelPort): Promise<Response> {
  const catalog = await model.catalog()
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    ...catalog.default === undefined ? {} : { default: catalog.default },
    groups: [...catalog.groups],
    failures: [...catalog.failures],
  }
}

/** 列表路径：廉价的每会话元数据，最新在前。 */
async function listSessions(port: SessionPort, now: () => number): Promise<Response> {
  const summaries = [...await port.list()]
  // 在此排序而非在客户端排，让所有客户端的顺序一致。
  summaries.sort((left, right) => right.updatedAt - left.updatedAt)
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    serverTime: now(),
    sessions: summaries.map(toWireSummary),
  }
}

/**
 * 一行的线上形状，省略 `title` 而非发送 null。`eventCount` 刻意缺席：
 * 日志推导的事实会把日志拖回列表路径（dev/contract/protocol.md §4.1）。
 */
function toWireSummary(row: SessionRow): Record<string, unknown> {
  return {
    id: row.id,
    ...row.title === undefined ? {} : { title: row.title },
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    running: row.running,
    blank: row.blank,
    ...row.origin === undefined ? {} : { origin: row.origin },
  }
}

/** 读路径：一个会话自客户端水位之后的事件。 */
async function snapshot(envelope: Record<string, unknown>, port: SessionPort, limits: Limits): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    // 用 `unknown-session` 而非新码：不是非空字符串的 id 永远不可能命名
    // 已存储的会话，调用方的补救相同。
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }

  const since = normalizeSince(envelope.since)
  const slice = await port.read(sessionId, since, limits.maxDeltaEvents)
  if (slice === undefined) return failure('unknown-session', `no stored session "${sessionId}"`)

  if (slice.staleCursor) {
    // 用错误码，不用静默空应答：整个视图已不可信，布尔会被吞掉
    // （dev/contract/protocol.md §六）。
    return failure('resync-required', `since ${since} cannot exist: this session's log is empty`)
  }

  const events = fitToByteCap(slice.events, limits.maxDeltaBytes)
  const last = events.at(-1)
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    sessionId,
    asOfSeq: last === undefined ? since : last.seq + 1,
    hasMore: slice.hasMore || events.length < slice.events.length,
    events: [...events],
    // 基线随每条 snapshot 应答随行；缺省仍是缺省。
    ...slice.model === undefined ? {} : { model: slice.model },
  }
}

/**
 * 反向窗口：最新 `maxMessages` 条消息，或恰好终止于 `beforeSeq` 之前的
 * 一轮 —— 边界规则见 `contract/window.ts` 的 `pageWindow`。
 */
async function page(envelope: Record<string, unknown>, port: SessionPort): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }

  const maxMessages = isPositiveInteger(envelope.maxMessages)
    ? envelope.maxMessages
    : DEFAULT_PAGE_MESSAGES

  // 畸形 `beforeSeq` 退化为最新窗口，正如畸形 `since` 退化为 `0`：
  // 是合法应答，至多多付一个窗口。
  const requested = envelope.beforeSeq
  const beforeSeq = Number.isSafeInteger(requested) && (requested as number) >= 0
    ? requested as number
    : undefined

  const events = await port.readAll(sessionId)
  if (events === undefined) return failure('unknown-session', `no stored session "${sessionId}"`)

  let window: PageWindow
  try {
    window = pageWindow(sessionId, events, beforeSeq, maxMessages)
  } catch (error) {
    // 两种拒绝：不可解读的日志是 `unreadable-session`，cursor 越过末端是
    // `resync-required`（M1 判据 P4）。
    if (error instanceof LogNotDenseError) return failure('unreadable-session', error.message)
    if (error instanceof CursorPastEndError) return failure('resync-required', error.message)
    throw error
  }

  return {
    v: PROTOCOL_VERSION,
    ok: true,
    sessionId,
    pageStart: window.pageStart,
    asOfSeq: window.asOfSeq,
    hasOlder: window.hasOlder,
    events: [...window.events],
  }
}

/**
 * 保留 `events` 在字节上限内能装下的最长前缀。上限是软的：把事件全丢掉
 * 会让客户端无法前进，所以第一条事件即使独自超限也要放行 —— 恰是这一点
 * 约束住病态应答。
 */
function fitToByteCap(events: readonly WireEvent[], maxBytes: number): readonly WireEvent[] {
  const kept: WireEvent[] = []
  let bytes = 0
  for (const event of events) {
    const size = wireBytesOf(event)
    if (kept.length > 0 && bytes + size > maxBytes) break
    kept.push(event)
    bytes += size
  }
  return kept
}

/**
 * 一条事件的序列化尺寸。用 `TextEncoder` 而非 `Buffer`：不依赖宿主特有
 * API，消息走到哪里就能在哪里运行。
 */
function wireBytesOf(event: WireEvent): number {
  return ENCODER.encode(JSON.stringify(event)).length
}

const ENCODER = new TextEncoder()

/** 无意义的上限不得变成卡死：非正或非整数即回退默认值。 */
export function positiveOrDefault(value: number | undefined, fallback: number): number {
  return value !== undefined && isPositiveInteger(value) ? value : fallback
}

/**
 * 三条上限各自归一化。无意义的值绝不产生任何客户端都读不完的应答 ——
 * 在流通道上后果更重：一个非正的上界会让每一次打开都被判成「装不下」。
 */
function normalizeLimits(limits: Limits): Limits {
  return {
    maxDeltaEvents: positiveOrDefault(limits.maxDeltaEvents, DEFAULT_LIMITS.maxDeltaEvents),
    maxDeltaBytes: positiveOrDefault(limits.maxDeltaBytes, DEFAULT_LIMITS.maxDeltaBytes),
    maxOpeningBytes: positiveOrDefault(limits.maxOpeningBytes, DEFAULT_LIMITS.maxOpeningBytes),
  }
}

/** `value` 能否作为循环的上界。 */
function isPositiveInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0
}

/**
 * 缺失或无意义的 `since` 读作 `0` —— 「把一切发我」—— 而非新错误码：
 * 客户端按 `seq` 去重，宽容的代价只是冗余载荷，绝不是错误视图。
 */
function normalizeSince(value: unknown): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : 0
}

/** 纯对象，区别于数组、null 或原始值。 */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined
}

/** 构造拒绝。每条拒绝都带 `v`，与成功应答完全一致。 */
function failure(code: string, message: string): ErrorResponse {
  return { v: PROTOCOL_VERSION, ok: false, error: { code, message } }
}
