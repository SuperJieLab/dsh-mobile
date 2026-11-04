/**
 * 协议契约：一条线上消息进，一条线上消息出。
 *
 * `handle` 是注入数据源的普通 async 函数：无 HTTP、无 socket、无 DSH 运行时、
 * 无会话存储。所有传输原样复用它 —— 协议是消息，不是 URL。水位：两个边界
 * 均为半开。`since` 是客户端*下一个期望的 seq*（`0` = 「我什么都没有」）；
 * `asOfSeq` 是「已覆盖到、不含」，并作为 `since` 回传，因此永远不会漏取或
 * 重取。两种不重叠的读取：`snapshot` 自 cursor 前向，`page` 反向取一个
 * 用于打开的窗口。
 *
 * 应答上限：单条应答 ≤ `maxDeltaEvents` 条事件，软性再受 `maxDeltaBytes`
 * 约束；提前截停用 `hasMore` 说明。上限约束的是单条应答，从不是序列的累计。
 */

import { readErrorOf } from './error-codes.ts'
import type { SessionPort } from '../ports/session.ts'
import type { ModelPort } from '../ports/model.ts'
import type { WritePort } from '../ports/write.ts'
import type { CommandPort } from '../ports/command.ts'
import type { PermissionPort } from '../ports/permission.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import { PROTOCOL_VERSION } from '../wire/rpc.ts'
import type {
  WireEvent,
  SessionRow,
  ErrorResponse,
  OkResponse,
  Response,
} from '../wire/rpc.ts'
import { modelSelectRequestOf } from '../wire/model.ts'
import { commandExecuteRequestOf } from '../wire/command.ts'
import { permissionSelectRequestOf } from '../wire/permission.ts'
import { approvalAnswerOf, sessionCreateTargetOf, sessionPromptOf } from '../wire/write.ts'
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
   * follow 打开那一帧的字节上界（R9 期1）。它与上面两个不同：**不经由本文件的
   * `handle`，而且是硬上限** —— 装不下就按轮边界收窄，连一轮都装不下则拒绝。
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
 * 应答一条消息。
 *
 * @param message - 解析后的 JSON 主体，构造上形状未知。
 * @param ports - 数据源；所有读都经它。缺席的端口对应的 op 一律拒答（见各分支）。
 * @param now - `serverTime` 用的时钟，可注入以保测试确定性。
 * @param limits - 应答上限；无意义值回退到 {@link DEFAULT_LIMITS}，
 *   绝不产生客户端永远无法读完的应答。
 * @returns 应答信封。从不抛错：敌意或卡死的数据源会变成拒绝
 *   （「进程不得崩溃」是判定过的判据）。
 */
export async function handle(
  message: unknown,
  ports: Ports,
  now: () => number = Date.now,
  limits: Limits = DEFAULT_LIMITS,
): Promise<Response> {
  const { session: port, write, model, command, workspace, permission } = ports
  const envelope = asRecord(message)
  if (envelope === undefined || envelope.v !== PROTOCOL_VERSION) {
    // 文案带方向：「版本不一致」本身不可行动，而两个方向要做的补救完全不同。
    return failure('unsupported-version', versionRefusalOf(envelope?.v))
  }

  const op = envelope.op
  if (typeof op !== 'string') return failure('unknown-op', 'request has no op')

  try {
    switch (op) {
      case 'list-sessions':
        return await listSessions(port, workspace, now)
      case 'snapshot':
        return await snapshot(envelope, port, normalizeLimits(limits))
      case 'page':
        return await page(envelope, port)
      case 'model-catalog':
        // 读 op。端口缺席是装配层宣布过的事实（`faces.ts` 在宿主没有模型切面时
        // 返回 undefined 并留痕），所以这一支在生产也可达 —— 拒答而不是崩。
        if (model === undefined) return failure('internal-error', 'model channel not wired for "model-catalog"')
        return await modelCatalog(model)
      case 'model-select':
        // 写 op，与写通道的 op 同一纪律。
        if (model === undefined) return failure('internal-error', 'model channel not wired for "model-select"')
        return await modelSelect(envelope, model)
      case 'command-catalog':
        // 仅只读测试装配会缺这个端口：生产装配的命令端口总在，服务缺席由那次调用抛出
        // （折成 `internal-error`），不在这里判。
        if (command === undefined) return failure('internal-error', `command channel not wired for "${op}"`)
        return await commandCatalog(envelope, command)
      case 'command-execute':
        // 写 op：整行原样交给宿主，但「是不是一条命令行」在这里先判。
        if (command === undefined) return failure('internal-error', `command channel not wired for "${op}"`)
        return await commandExecute(envelope, command)
      case 'permission-catalog':
        // 读 op。端口缺席只发生在只读测试装配里；生产装配的端口总在，而「权限服务
        // 没装」这件事由端口自己用「options 缺席」表达，不在这里判。
        if (permission === undefined) return failure('internal-error', `permission channel not wired for "${op}"`)
        return await permissionCatalog(envelope, permission)
      case 'permission-select':
        // 写 op：线上只收预设名，拼命令与目录校验都在适配层。
        if (permission === undefined) return failure('internal-error', `permission channel not wired for "${op}"`)
        return await permissionSelect(envelope, permission)
      case 'session-create': {
        // 写 op（建实体）。载荷只有一格：落在哪个工作空间；不带就交给宿主当前目录。
        if (write === undefined) return failure('internal-error', `write channel not wired for "${op}"`)
        const target = sessionCreateTargetOf(envelope)
        if (target.kind === 'invalid') {
          return failure('invalid-request', 'session-create accepts a non-empty workspaceId or none')
        }
        return await sessionCreate(write, target.kind === 'workspace' ? target.workspaceId : undefined)
      }
      case 'workspace-create':
        // 写 op（造目录 + 注册）。名字不合法时**一个文件系统调用都不发生**。
        if (workspace === undefined) return failure('internal-error', `workspace channel not wired for "${op}"`)
        return await workspaceCreate(envelope, workspace)
      case 'workspace-delete':
        // 写 op（解注册）。只删注册 —— 目录与会话日志都由宿主留着。
        if (workspace === undefined) return failure('internal-error', `workspace channel not wired for "${op}"`)
        return await workspaceDelete(envelope, workspace)
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
    // 其余是我们的错。规则本身在 `./error-codes.ts` —— 与流通道那份并列，不合并。
    const refusal = readErrorOf(error)
    return failure(refusal.code, refusal.message)
  }
}

/**
 * 建一个空会话。`ok` 意为**宿主建出来或复用了**一个空会话，`sessionId` 是它给的那个 ——
 * 网关不造 id、也不缓存：列表是会话的真相，这里只负责把这一次创建的结果答回去。
 *
 * 宿主失败**不在这里折**：`handle` 的 catch 用 `readErrorOf` 统一折成 `internal-error`
 * 并把上游的话带进 message。本层不记日志（与其余 op 一致），排障看宿主侧。
 */
async function sessionCreate(write: WritePort, workspaceId: string | undefined): Promise<Response> {
  return success({ sessionId: await write.createSession(workspaceId) })
}

/**
 * 在固定根下造一个工作空间。
 *
 * 名字不合法时在这里就拒，**不碰文件系统** —— 形状与语义合成一次判断，因为对客户端
 * 而言两者的补救动作相同（改字重发）。
 */
async function workspaceCreate(
  envelope: Record<string, unknown>,
  workspace: WorkspacePort,
): Promise<Response> {
  const name = workspaceNameOf(envelope)
  if (name === undefined) {
    return failure('invalid-request', 'workspace-create needs a name that is one non-blank path segment')
  }
  const made = await workspace.create(name)
  return success({ workspaceId: made.workspaceId, title: made.title, created: made.created })
}

/**
 * 解除一个工作空间的注册。
 *
 * `ok` 意为**它已经不在列表里了** —— 是真删掉的、还是本来就没有，客户端不需要知道
 * （两种结局要做的事完全一样：关掉确认框、重拉一次）。所以应答里没有 `deleted`。
 *
 * 宿主失败**不在这里折**：`handle` 的 catch 用 `readErrorOf` 统一折成 `internal-error`。
 * 「删一个已经不在的算成功」那条住在适配层（`deleteWorkspaceIn`），它认得 not-found。
 */
async function workspaceDelete(
  envelope: Record<string, unknown>,
  workspace: WorkspacePort,
): Promise<Response> {
  const workspaceId = workspaceIdOf(envelope)
  if (workspaceId === undefined) {
    return failure('invalid-request', 'workspace-delete needs a non-blank workspaceId')
  }
  await workspace.delete(workspaceId)
  return success({})
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

/**
 * 命令列表：该会话此刻能用的命令，名字与说明原样。
 *
 * 会话不在 → `unknown-session`（不是空列表）：没有 agent 就没有 per-agent 的命令集，
 * 空列表会让客户端把「这个会话没了」误读成「这个会话没有命令」。
 */
async function commandCatalog(envelope: Record<string, unknown>, command: CommandPort): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }
  const commands = await command.list(sessionId)
  if (commands === undefined) return failure('unknown-session', `no live session "${sessionId}"`)
  return { v: PROTOCOL_VERSION, ok: true, commands: [...commands] }
}

/**
 * 执行一行命令。`ok` 意为*已受理* —— 结果从流里的 `command/run` / `command/done` 来，
 * 回包里没有、也不该有执行结果。
 *
 * 两类拒绝保留自己的码：`unknown-command` 说那一行解析不出已注册的命令（客户端改字），
 * 与「这条命令执行失败」（流里的那一行）是不同的补救。
 */
async function commandExecute(envelope: Record<string, unknown>, command: CommandPort): Promise<Response> {
  const request = commandExecuteRequestOf(envelope)
  if (request === undefined) {
    return failure('invalid-request', 'command-execute needs sessionId and a line starting with "/"')
  }
  const outcome = await command.execute(request.sessionId, request.line)
  if (!outcome.ok) return failure(outcome.code, outcome.message)
  return { v: PROTOCOL_VERSION, ok: true, commandId: outcome.commandId }
}

/**
 * 权限预设：该会话此刻能选什么、现在是什么。
 *
 * 两格都可以缺席，含义不同（见 `wire/permission.ts`）—— `options` 缺席 = 这个装配没有
 * 权限服务，客户端据此不画那一格；`current` 缺席 = 宿主不知道，客户端显示 `--`。
 * 两者都不补默认值：补出来的档位会与 Web UI 显示的那个不一致。
 */
async function permissionCatalog(
  envelope: Record<string, unknown>,
  permission: PermissionPort,
): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }
  const view = await permission.catalog(sessionId)
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    ...view.current === undefined ? {} : { current: view.current },
    ...view.options === undefined ? {} : { options: [...view.options] },
  }
}

/**
 * 切到一档。`ok` 意为*宿主已受理* —— 落地证据是流里的 `permission/preset` 与随之的两个
 * knob 事件；回包里的 `current` 是受理后重读投影拿到的值。
 *
 * 两类拒绝保留自己的码：`unknown-preset` 说这个名字不在宿主目录里（客户端重拉目录再选），
 * `unknown-session` 说会话没有活着的 agent（切不了）。
 */
async function permissionSelect(
  envelope: Record<string, unknown>,
  permission: PermissionPort,
): Promise<Response> {
  const request = permissionSelectRequestOf(envelope)
  if (request === undefined) {
    return failure('invalid-request', 'permission-select needs sessionId and a non-empty preset')
  }
  const outcome = await permission.select(request.sessionId, request.preset)
  if (!outcome.ok) return failure(outcome.code, outcome.message)
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    ...outcome.current === undefined ? {} : { current: outcome.current },
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
async function listSessions(
  port: SessionPort,
  workspace: WorkspacePort | undefined,
  now: () => number,
): Promise<Response> {
  const summaries = [...await port.list()]
  // 在此排序而非在客户端排，让所有客户端的顺序一致。
  summaries.sort((left, right) => right.updatedAt - left.updatedAt)
  const groups = workspace?.snapshot()
  return {
    v: PROTOCOL_VERSION,
    ok: true,
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
    // 用错误码，不用静默空应答：整个视图已不可信，布尔会被吞掉。
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
 * 一轮 —— 边界规则见 `./window.ts` 的 `pageWindow`。
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

/**
 * 版本不匹配的拒绝文案。**带方向**。
 *
 * 「两端版本不一致」这句话本身不可行动：客户端看到它不知道该升级自己还是升级网关。
 * 方向从版本号大小就能读出来 —— 客户端说的比自己小，是客户端旧；比自己的大，是自己旧。
 *
 * 客户端那一侧不解析这句话（它拿应答的 `v` 自己判方向，文案在 `FailureText`）；
 * 这里的句子是给日志与手工 curl 用的，所以用英文，与其余协议 message 一致。
 */
function versionRefusalOf(sent: unknown): string {
  if (typeof sent !== 'number') {
    return `expected an object with v: ${PROTOCOL_VERSION}`
  }
  if (sent < PROTOCOL_VERSION) {
    return `this gateway speaks protocol v${PROTOCOL_VERSION}, the request said v${sent} — upgrade the client`
  }
  return `this gateway speaks protocol v${PROTOCOL_VERSION}, the request said v${sent} — upgrade the gateway`
}

/**
 * 构造拒绝。每条拒绝都带 `v`，与成功应答完全一致。
 *
 * **导出是为了让传输层用它，而不是自己再写一份**：`pair` / `refresh` 绕过
 * `handle`（凭据在体内），所以 `remote/http.ts` 也要作答；它只能引用这里，
 * 不能手写 `{ v, ok: false, error }` —— 那样版本号与字段集就各有一份活法。
 */
export function failure(code: string, message: string): ErrorResponse {
  return { v: PROTOCOL_VERSION, ok: false, error: { code, message } }
}

/**
 * 构造成功应答。与 {@link failure} 成对：信封的两个固定字段（`v` / `ok`）
 * 只在这两个函数里出现，其余地方只交出各自 op 的字段。
 *
 * 泛型保留调用方给的字段，所以 `success({ deviceToken })` 的类型里仍有
 * `deviceToken`，能直接填进 `PairResponse`。
 */
export function success<T extends Record<string, unknown>>(fields: T): OkResponse & T {
  return { v: PROTOCOL_VERSION, ok: true, ...fields }
}
