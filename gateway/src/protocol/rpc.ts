/**
 * 协议判定：一条端点调用进，一个 `RemoteResult` 出。
 *
 * 注入数据源的普通 async 函数：无 HTTP、无 socket、无 DSH 运行时、无会话存储。
 * 传输层（`remote/http.ts`）与测试辅助都经 `protocol/unary-endpoints.ts` 的表找到
 * 这里 —— **本文件不认识 URL**，也不认识信封，它只回答「这次调用成没成、值是什么」。
 *
 * 水位：两个边界均为半开。`since` 是客户端*下一个期望的 seq*（`0` = 「我什么都没有」）；
 * `asOfSeq` 是「已覆盖到、不含」，并作为 `since` 回传，因此永远不会漏取或重取。
 * 两种不重叠的读取：`snapshot` 自 cursor 前向，`page` 反向取一个用于打开的窗口。
 *
 * 应答上限：单条应答 ≤ `maxDeltaEvents` 条事件，软性再受 `maxDeltaBytes` 约束；
 * 提前截停用 `hasMore` 说明。上限约束的是单条应答，从不是序列的累计。
 */

import type { SessionPort } from '../ports/session.ts'
import type { ModelPort } from '../ports/model.ts'
import type { WritePort } from '../ports/write.ts'
import type { CommandPort } from '../ports/command.ts'
import type { PermissionPort } from '../ports/permission.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import type { RemoteResult } from '../wire/unary.ts'
import type { WireEvent, SessionRow } from '../wire/rpc.ts'
import { modelSelectRequestOf } from '../wire/model.ts'
import { commandExecuteRequestOf } from '../wire/command.ts'
import { permissionSelectRequestOf } from '../wire/permission.ts'
import { approvalAnswerOf, sessionPromptOf } from '../wire/write.ts'
import { workspaceIdOf, workspaceNameOf } from '../wire/workspace.ts'
import { isPositiveInteger } from '../wire/fields.ts'
import { LogNotDenseError, CursorPastEndError, pageWindow } from './window.ts'
import type { PageWindow } from '../wire/window.ts'

/**
 * 一条 `snapshot` 应答可能有多大；只约束单条应答，从不是客户端的视图。
 */
export interface Limits {
  /** 单条应答至多携带的事件数。必须为正。 */
  maxDeltaEvents: number
  /** 单条应答 `events` 序列化尺寸的软上限。 */
  maxDeltaBytes: number
  /**
   * follow 打开那一帧的字节上界（R9 期1）。它与上面两个不同：**不经过一元端点，
   * 而且是硬上限** —— 装不下就按轮边界收窄，连一轮都装不下则拒绝。
   * HTTP 路径的软上限允许首条事件独自超限放行（否则客户端无法前进），那条规则
   * 在这里等于必然断连，不能照搬。
   */
  maxOpeningBytes: number
}

/**
 * LAN 演示的上限：宽到很少生效，小到确实有界。`maxOpeningBytes` 取 4 MiB ——
 * 比一个典型会话的整条窗口宽出数倍，于是普通会话根本不进收窄路径。
 */
export const DEFAULT_LIMITS: Limits = { maxDeltaEvents: 500, maxDeltaBytes: 1_048_576, maxOpeningBytes: 4 * 1024 * 1024 }

/**
 * 调用方不指定时一条 `page` 返回的消息数；对照参考客户端的页大小。
 * 这是*窗口*，不是上限：这里没有 `hasMore` 循环。
 */
export const DEFAULT_PAGE_MESSAGES = 50


/**
 * 一次调用要用到的数据源。
 *
 * **具名，不按位置。** 除 `session` 外都可选，而可选参数按位置传时「顺序写错」不会
 * 编译失败 —— 它会让某个 op 拿到另一个端口，在运行时表现为「权限 op 读到了工作空间」
 * 这类静默错位。具名之后，漏传是缺席、传错是类型错。
 */
export interface Ports {
  /** 读路径与列表路径的唯一必需依赖。 */
  session: SessionPort
  write?: WritePort
  model?: ModelPort
  command?: CommandPort
  workspace?: WorkspacePort
  permission?: PermissionPort
}

/**
 * 建一个空会话。`ok` 意为**宿主建出来或复用了**一个空会话，`sessionId` 是它给的那个 ——
 * 网关不造 id、也不缓存：列表是会话的真相，这里只负责把这一次创建的结果答回去。
 *
 * 宿主失败**不在这里折**：`invokeEndpoint` 的 catch 用 `readErrorOf` 统一折成
 * `internal-error` 并把上游的话带进 message。本层不记日志，排障看宿主侧。
 */
export async function sessionCreateOf(
  write: WritePort | undefined,
  workspaceId: string | undefined,
): Promise<RemoteResult> {
  // 仅只读测试装配会缺 `write`；生产必接线，此拒绝在生产不可达。
  if (write === undefined) return refused('internal-error', 'write channel not wired for "session-create"')
  return { ok: true, value: { sessionId: await write.createSession(workspaceId) } }
}

/**
 * 在固定根下造一个工作空间。
 *
 * 名字不合法时在这里就拒，**不碰文件系统** —— 形状与语义合成一次判断，因为对客户端
 * 而言两者的补救动作相同（改字重发）。
 */
export async function workspaceCreateOf(
  args: Record<string, unknown>,
  workspace: WorkspacePort | undefined,
): Promise<RemoteResult> {
  if (workspace === undefined) return refused('internal-error', 'workspace channel not wired for "workspace-create"')
  const name = workspaceNameOf(args)
  if (name === undefined) {
    return refused('invalid-request', 'workspace-create needs a name that is one non-blank path segment')
  }
  const made = await workspace.create(name)
  return {
    ok: true,
    value: { workspaceId: made.workspaceId, title: made.title, created: made.created },
  }
}

/**
 * 解除一个工作空间的注册。
 *
 * `ok` 意为**它已经不在列表里了** —— 是真删掉的、还是本来就没有，客户端不需要知道
 * （两种结局要做的事完全一样：关掉确认框、重拉一次）。所以应答里没有 `deleted`。
 *
 * 宿主失败**不在这里折**：`invokeEndpoint` 的 catch 用 `readErrorOf` 统一折成 `internal-error`。
 * 「删一个已经不在的算成功」那条住在适配层（`deleteWorkspaceIn`），它认得 not-found。
 */
export async function workspaceDeleteOf(
  args: Record<string, unknown>,
  workspace: WorkspacePort | undefined,
): Promise<RemoteResult> {
  if (workspace === undefined) return refused('internal-error', 'workspace channel not wired for "workspace-delete"')
  const workspaceId = workspaceIdOf(args)
  if (workspaceId === undefined) {
    return refused('invalid-request', 'workspace-delete needs a non-blank workspaceId')
  }
  await workspace.delete(workspaceId)
  return { ok: true, value: {} }
}

/**
 * 投递一条 approval 应答。`ok` 意为*已投递给挂起的问题* —— 权威结论
 * 是客户端从流中对账的 `approval/decided` 审计事件。
 */
export async function approvalAnswerValue(
  args: Record<string, unknown>,
  write: WritePort | undefined,
): Promise<RemoteResult> {
  if (write === undefined) return refused('internal-error', 'write channel not wired for "approval-answer"')
  const answer = approvalAnswerOf(args)
  if (answer === undefined) {
    return refused('invalid-request', 'approval-answer needs eventId, decision ("allow" | "deny"), and answerId')
  }
  const outcome = await write.answerApproval(answer)
  if (outcome === 'unknown-approval') {
    return refused('unknown-approval', `no pending approval answers to "${answer.eventId}" — already decided, cancelled, or never asked`)
  }
  if (outcome === 'undelivered') {
    // 上游拒了这条回答：问题仍挂在它那里等着，所以这里不能说 `ok`（`ok` 意为
    // 「已投递给挂起的问题」）。原因在上游的 code 里，网关日志已记。
    return refused('internal-error', `the gateway refused the answer for "${answer.eventId}" — see the gateway log for its code`)
  }
  return { ok: true, value: { eventId: answer.eventId } }
}

/**
 * 收纳一条 prompt。`ok` 意为*已接受进收件箱* —— 回复本体经流到达。
 */
export async function sessionPromptValue(
  args: Record<string, unknown>,
  write: WritePort | undefined,
): Promise<RemoteResult> {
  if (write === undefined) return refused('internal-error', 'write channel not wired for "session-prompt"')
  const prompt = sessionPromptOf(args)
  if (prompt === undefined) {
    return refused('invalid-request', 'session-prompt needs sessionId, promptId, and non-whitespace text')
  }
  const outcome = await write.promptSession(prompt)
  if (outcome === 'unknown-session') {
    return refused('unknown-session', `no stored session "${prompt.sessionId}"`)
  }
  return { ok: true, value: { sessionId: prompt.sessionId } }
}

/**
 * 安装一条会话级模型选择。`ok` 意为*已为下一个请求装好* —— 持久的
 * `model/selection` 事件经流到达客户端，展示对账的正是它。
 * 上游的拒绝保留自己的码：`session/model-unavailable` 说模型不可路由，
 * 与畸形请求是不同的补救。
 */
export async function modelSelectOf(
  args: Record<string, unknown>,
  model: ModelPort | undefined,
): Promise<RemoteResult> {
  if (model === undefined) return refused('internal-error', 'model channel not wired for "model-select"')
  const request = modelSelectRequestOf(args)
  if (request === undefined) {
    return refused('invalid-request', 'model-select needs sessionId, provider, and model')
  }
  const outcome = await model.select(request)
  if (!outcome.ok) return refused(outcome.code, outcome.message)
  return { ok: true, value: { selected: { ...outcome.selected } } }
}

/** 模型目录路径：宿主目录原样，去掉客户端用不上的字段。 */
/**
 * 模型目录的业务字段。端口缺席是装配层宣布过的事实（`faces.ts` 在宿主没有模型切面时
 * 返回 `undefined` 并留痕），所以这一支在生产也可达 —— 拒答而不是崩。
 */
export async function modelCatalogOf(model: ModelPort | undefined): Promise<RemoteResult> {
  if (model === undefined) return refused('internal-error', 'model channel not wired for "model-catalog"')
  const catalog = await model.catalog()
  return {
    ok: true,
    value: {
      ...catalog.default === undefined ? {} : { default: catalog.default },
      groups: [...catalog.groups],
      failures: [...catalog.failures],
    },
  }
}

/**
 * 命令列表：该会话此刻能用的命令，名字与说明原样。
 *
 * 会话不在 → `unknown-session`（不是空列表）：没有 agent 就没有 per-agent 的命令集，
 * 空列表会让客户端把「这个会话没了」误读成「这个会话没有命令」。
 */
export async function commandCatalogOf(
  args: Record<string, unknown>,
  command: CommandPort | undefined,
): Promise<RemoteResult> {
  // 仅只读测试装配会缺这个端口：生产装配的命令端口总在，服务缺席由那次调用抛出
  // （折成 `internal-error`），不在这里判。
  if (command === undefined) return refused('internal-error', 'command channel not wired for "command-catalog"')
  const sessionId = args.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return refused('unknown-session', 'sessionId must be a non-empty string')
  }
  const commands = await command.list(sessionId)
  if (commands === undefined) return refused('unknown-session', `no live session "${sessionId}"`)
  return { ok: true, value: { commands: [...commands] } }
}

/**
 * 执行一行命令。`ok` 意为*已受理* —— 结果从流里的 `command/run` / `command/done` 来，
 * 回包里没有、也不该有执行结果。
 *
 * 两类拒绝保留自己的码：`unknown-command` 说那一行解析不出已注册的命令（客户端改字），
 * 与「这条命令执行失败」（流里的那一行）是不同的补救。
 */
export async function commandExecuteOf(
  args: Record<string, unknown>,
  command: CommandPort | undefined,
): Promise<RemoteResult> {
  if (command === undefined) return refused('internal-error', 'command channel not wired for "command-execute"')
  const request = commandExecuteRequestOf(args)
  if (request === undefined) {
    return refused('invalid-request', 'command-execute needs sessionId and a line starting with "/"')
  }
  const outcome = await command.execute(request.sessionId, request.line)
  if (!outcome.ok) return refused(outcome.code, outcome.message)
  return { ok: true, value: { commandId: outcome.commandId } }
}

/**
 * 权限预设：该会话此刻能选什么、现在是什么。
 *
 * 两格都可以缺席，含义不同（见 `wire/permission.ts`）—— `options` 缺席 = 这个装配没有
 * 权限服务，客户端据此不画那一格；`current` 缺席 = 宿主不知道，客户端显示 `--`。
 * 两者都不补默认值：补出来的档位会与 Web UI 显示的那个不一致。
 */
export async function permissionCatalogOf(
  args: Record<string, unknown>,
  permission: PermissionPort | undefined,
): Promise<RemoteResult> {
  // 端口缺席只发生在只读测试装配里；生产装配的端口总在，而「权限服务没装」这件事
  // 由端口自己用「options 缺席」表达，不在这里判。
  if (permission === undefined) return refused('internal-error', 'permission channel not wired for "permission-catalog"')
  const sessionId = args.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return refused('unknown-session', 'sessionId must be a non-empty string')
  }
  const view = await permission.catalog(sessionId)
  return {
    ok: true,
    value: {
      ...view.current === undefined ? {} : { current: view.current },
      ...view.options === undefined ? {} : { options: [...view.options] },
    },
  }
}

/**
 * 切到一档。`ok` 意为*宿主已受理* —— 落地证据是流里的 `permission/preset` 与随之的两个
 * knob 事件；回包里的 `current` 是受理后重读投影拿到的值。
 *
 * 两类拒绝保留自己的码：`unknown-preset` 说这个名字不在宿主目录里（客户端重拉目录再选），
 * `unknown-session` 说会话没有活着的 agent（切不了）。
 */
export async function permissionSelectOf(
  args: Record<string, unknown>,
  permission: PermissionPort | undefined,
): Promise<RemoteResult> {
  if (permission === undefined) return refused('internal-error', 'permission channel not wired for "permission-select"')
  const request = permissionSelectRequestOf(args)
  if (request === undefined) {
    return refused('invalid-request', 'permission-select needs sessionId and a non-empty preset')
  }
  const outcome = await permission.select(request.sessionId, request.preset)
  if (!outcome.ok) return refused(outcome.code, outcome.message)
  return {
    ok: true,
    value: {
      ...outcome.current === undefined ? {} : { current: outcome.current },
    },
  }
}

/**
 * 列表应答：会话行 + 工作空间清单。
 *
 * 两样出自**同一次**读取（`snapshot()` 一次），所以不存在「清单里没有、归属里
 * 却有」这种半新半旧的应答。端口缺席时清单这一格整个不发 —— 那是「这个装配没有
 * 分组能力」，与「宿主里没有工作空间」（空数组）是两件事，客户端两种都按
 * 「没有组」处理，但线上不能混成一种。
 */
/**
 * 列表应答的**业务字段**（不含信封）。
 *
 * 单独一个函数是为了两条通道共用同一份装配：旧的一元路径包 `{v, ok}`，新的端点路径
 * 包 `{type, rpcId, result}`。把装配抄第二遍，两条路径迟早会在某个字段上分叉，
 * 而分叉的症状是「同一个列表在两个入口长得不一样」。
 */
export async function listSessionsOf(
  port: SessionPort,
  workspace: WorkspacePort | undefined,
  now: () => number,
): Promise<Record<string, unknown>> {
  const summaries = [...await port.list()]
  // 在此排序而非在客户端排，让所有客户端的顺序一致。
  summaries.sort((left, right) => right.updatedAt - left.updatedAt)
  const groups = workspace?.snapshot()
  return {
    serverTime: now(),
    ...groups === undefined ? {} : { workspaces: groups.rows },
    sessions: summaries.map(row => toWireSummary(row, groups?.owners.get(row.id))),
  }
}

/**
 * 一行的线上形状，省略 `title` 而非发送 null。`eventCount` 刻意缺席：
 * 日志推导的事实会把日志拖回列表路径。
 *
 * `workspaceId` 由**这一层**补上而不是由数据源给：归属不是会话的事实，而是
 * 「会话与工作空间的关系」，它的唯一来源是工作空间注册表。让适配器去填这一格，
 * 等于让会话存储认识工作空间。
 */
function toWireSummary(row: SessionRow, workspaceId: string | undefined): Record<string, unknown> {
  return {
    id: row.id,
    ...row.title === undefined ? {} : { title: row.title },
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    running: row.running,
    blank: row.blank,
    ...row.origin === undefined ? {} : { origin: row.origin },
    ...workspaceId === undefined ? {} : { workspaceId },
  }
}

/** 读路径：一个会话自客户端水位之后的事件。 */
export async function snapshotOf(
  args: Record<string, unknown>,
  port: SessionPort,
  limits: Limits,
): Promise<RemoteResult> {
  const sessionId = args.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    // 用 `unknown-session` 而非新码：不是非空字符串的 id 永远不可能命名
    // 已存储的会话，调用方的补救相同。
    return refused('unknown-session', 'sessionId must be a non-empty string')
  }

  const since = normalizeSince(args.since)
  const slice = await port.read(sessionId, since, limits.maxDeltaEvents)
  if (slice === undefined) return refused('unknown-session', `no stored session "${sessionId}"`)

  if (slice.staleCursor) {
    // 用错误码，不用静默空应答：整个视图已不可信，布尔会被吞掉。
    return refused('resync-required', `since ${since} cannot exist: this session's log is empty`)
  }

  const events = fitToByteCap(slice.events, limits.maxDeltaBytes)
  const last = events.at(-1)
  return {
    ok: true,
    value: {
      sessionId,
      asOfSeq: last === undefined ? since : last.seq + 1,
      hasMore: slice.hasMore || events.length < slice.events.length,
      events: [...events],
      // 基线随每条 snapshot 应答随行；缺省仍是缺省。
      ...slice.model === undefined ? {} : { model: slice.model },
    },
  }
}

/**
 * 反向窗口：最新 `maxMessages` 条消息，或恰好终止于 `beforeSeq` 之前的
 * 一轮 —— 边界规则见 `./window.ts` 的 `pageWindow`。
 */
export async function pageOf(
  args: Record<string, unknown>,
  port: SessionPort,
): Promise<RemoteResult> {
  const sessionId = args.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return refused('unknown-session', 'sessionId must be a non-empty string')
  }

  const maxMessages = isPositiveInteger(args.maxMessages)
    ? args.maxMessages
    : DEFAULT_PAGE_MESSAGES

  // 畸形 `beforeSeq` 退化为最新窗口，正如畸形 `since` 退化为 `0`：
  // 是合法应答，至多多付一个窗口。
  const requested = args.beforeSeq
  const beforeSeq = Number.isSafeInteger(requested) && (requested as number) >= 0
    ? requested as number
    : undefined

  const events = await port.readAll(sessionId)
  if (events === undefined) return refused('unknown-session', `no stored session "${sessionId}"`)

  let window: PageWindow
  try {
    window = pageWindow(sessionId, events, beforeSeq, maxMessages)
  } catch (error) {
    // 两种拒绝：不可解读的日志是 `unreadable-session`，cursor 越过末端是
    // `resync-required`（M1 判据 P4）。
    if (error instanceof LogNotDenseError) return refused('unreadable-session', error.message)
    if (error instanceof CursorPastEndError) return refused('resync-required', error.message)
    throw error
  }

  return {
    ok: true,
    value: {
      sessionId,
      pageStart: window.pageStart,
      asOfSeq: window.asOfSeq,
      hasOlder: window.hasOlder,
      events: [...window.events],
    },
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
/**
 * 缺失或无意义的 `since` 读作 `0` —— 「把一切发我」—— 而非新错误码：
 * 客户端按 `seq` 去重，宽容的代价只是冗余载荷，绝不是错误视图。
 */
function normalizeSince(value: unknown): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : 0
}

/** 纯对象，区别于数组、null 或原始值。 */
/**
 * 一次失败的形状（三格，`details` 恒为对象）。
 *
 * 全仓唯一的失败构造点：处理器在判定不下去时用它，`invokeEndpoint` 折异常时也用它 ——
 * 于是「失败恒三键」这件事只有一个出处，而不是每个端点各拼一次。
 */
export function refused(
  code: string,
  message: string,
  details: Record<string, unknown> = {},
): RemoteResult {
  return { ok: false, error: { code, message, details } }
}

