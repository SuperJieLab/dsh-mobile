/**
 * 一条流：客户端发来的 open/cancel，与它起的那个泵。
 *
 * 存活范围是**一条流**。这个文件不碰连接状态（谁的心跳、这条 socket 上还有几条流），
 * 也不碰连接集合 —— 它只做三件事：把客户端帧路由成流、把源的事件泵成 mux 帧、
 * 把源的失败折成一条 error 帧。写出去经 `egress.ts`，不自己调 socket。
 *
 * 一条流失败时**只有这条结束**：泵的 catch 把异常折成 error 帧，`finally` 清掉
 * 自己的 streamId；同一条连接上的其它流继续。
 *
 * **本文件出现五条错误码，归属各不相同**（`ISSUES` A13 的分类结果）：
 *
 *   window-too-large   传输自有 —— 说的是「这一帧装不下」，由字节上界
 *                      （`StreamOptions.openingCapBytes`）产生，不是会话状态
 *   unknown-endpoint   端点名不在表里 —— 两端说不到一处，客户端重开也没用
 *   invalid-args       端点名对、入参不对 —— 同一处说错了东西，客户端的错
 *                      两条都由 `wire/endpoints.ts` 判出，这里只决定怎么回：
 *                      一条带编号的 error 帧，**连接与其他流不动**
 *   source-unavailable 事件源在、但这一代还没就绪 —— 给一份「看起来有、其实不知道」
 *                      的待答集合比拒绝更坏，所以拒绝；客户端按可重试处理（传输自有，
 *                      与上面两条同族，不进 `protocol/error-codes.ts` 的上游映射）
 *   internal-error     **这一条有三个产生者**：上游失败经映射（那种在
 *                      `protocol/error-codes.ts`）；本层自己发现的「源承诺无缺口、
 *                      实际却跳了 seq」—— 那不是上游抛的错，是传输在见证契约被违反；
 *                      以及「这条流要的源没接上」（装配错误）。三者同码，因为对客户端
 *                      而言补救相同（这条流已经不可信，换一条才有意义）。
 *
 * 其余由**上游失败**折出来的码（`unreadable-session` / `unknown-session`）不在这里：
 * 它们在 `protocol/error-codes.ts`，因为那套规则随上游的错误语义漂，而传输层不该
 * 为上游的形状变化负责。
 */

import {
  openRequestOf,
  parseClientFrame,
  type EventsValue,
  type FollowValue,
  type MuxApprovalWaterfall,
  type StreamId,
} from '../wire/mux.ts'
import { encodeServerFrame, type ControlValue } from '../wire/mux.ts'
import { fitOpeningToBytes } from '../protocol/window.ts'
import type { FollowSnapshot } from '../wire/mux.ts'
import { usageIsTrigger } from '../protocol/usage.ts'
import { randomUUID } from 'node:crypto'
import { describeError } from '../ports/errors.ts'
import type { FollowRequest } from '../wire/endpoints.ts'
import type { ApprovalSource, HeldApproval } from '../ports/approval.ts'
import { streamErrorOf } from '../protocol/error-codes.ts'
import type { FollowSource } from '../ports/follow.ts'
import type { ProjectionBaseline } from '../wire/rpc.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import type { ForwardedSource } from '../ports/events.ts'
import type { Duplex } from 'node:stream'
import { encodeTextFrame } from './frames.ts'
import type { IdentityRegistry } from './identity-registry.ts'
import { gwRecord, send, type PerfContext } from './egress.ts'
import { createLogger, LogModule, perfNow, perfRecord } from '../log.ts'

const log = createLogger(LogModule.ws)

/**
 * 一条客户端文本帧的处置结论 —— **本层只给结论，连接层才动手**。
 *
 * 「关不关这条 socket」超出「一条流」的存活范围，所以这里不碰 socket 的生死：它只回答
 * 这一帧归到哪儿。归得上（`ok`）就是这条流的事；归不上（`ok: false`）才升级成连接级，
 * 由调用方关掉它。
 */
export type ClientFrameOutcome =
  | { readonly ok: true }
  | { readonly ok: false; readonly reason: 'duplicate-id' }
  | { readonly ok: false; readonly reason: 'unreadable-frame'; readonly excerpt: string }

/** 记进日志的帧首长度：够认出「这是哪一版的客户端在说话」，又不至于把一整帧倒进日志。 */
const EXCERPT_LIMIT = 120

/**
 * 路由一条解析好的客户端文本帧：`open` 起泵，`cancel` 停泵。
 *
 * 两档分界的判据是**编号在不在手**，不是内容坏到什么程度：
 *
 *   - **编号在手**（信封完好）→ 这条流的事：端点名不认就回一条带该编号的 `unknown-endpoint`，
 *     连接与别的流不动。内容坏了不等于这条连接不可信 —— 它还能服务别的流。
 *   - **编号读不出**（不是 JSON、缺 `streamId`、`type` 不认识）→ 无从归流，报
 *     `unreadable-frame`，调用方关连接。
 *
 * `duplicate-id` 同理：同一个编号被第二次 `open`（编号约定不复用）意味着客户端坏了 ——
 * 再在这条连接上服务，每一条流都不可信。静默忽略更糟：客户端会等到 45 秒就绪超时才走，
 * 而那一帧到底发生了什么，两端日志都没有。
 */
export function onClientText(
  socket: Duplex,
  source: FollowSource,
  feed: ForwardedSource | undefined,
  approvals: ApprovalSource | undefined,
  workspace: WorkspacePort | undefined,
  registry: IdentityRegistry,
  streams: Map<StreamId, { abort: AbortController }>,
  text: string,
  openingCapBytes: number,
): ClientFrameOutcome {
  const frame = parseClientFrame(text)
  if (frame === undefined) return { ok: false, reason: 'unreadable-frame', excerpt: excerptOf(text) }

  if (frame.type === 'cancel') {
    // **只停泵，不动表**：条目由泵自己的收尾删（`pump` 的 `done`）。取消即删的话，
    // 之后同号的 `open` 会落进那个空档，而旧泵退出时的收尾删掉的是**新**条目 ——
    // 于是后续的 `cancel` 找不到它：流关不掉，同号还能再开一条并行。
    streams.get(frame.streamId)?.abort.abort()
    return { ok: true }
  }

  // 以下是 frame.type === 'open'
  if (streams.has(frame.streamId)) return { ok: false, reason: 'duplicate-id' }

  const request = openRequestOf(frame)
  if ('error' in request) {
    send(socket, {
      type: 'error',
      streamId: frame.streamId,
      error: { code: request.error, message: refusalMessageOf(request.error), details: {} },
    })
    return { ok: true }
  }

  const abort = new AbortController()
  streams.set(frame.streamId, { abort })
  const done = (): void => { streams.delete(frame.streamId) }

  // 装配缺了这一条要的源，就拒这一条 —— 拒绝要响：静默的表现是客户端等 45 秒就绪超时，
  // 而就绪超时判的是**整条连接**（所有流一起被关）。
  const refuse = (message: string): ClientFrameOutcome => {
    log.error('a stream opened but its source is not wired — refused',
      { stream: frame.streamId, endpoint: String(frame.endpoint) })
    streams.delete(frame.streamId)
    send(socket, {
      type: 'error',
      streamId: frame.streamId,
      error: { code: 'internal-error', message, details: {} },
    })
    return { ok: true }
  }

  if (request.kind === 'events') {
    if (feed === undefined || approvals === undefined) {
      return refuse('this gateway has no forwarded-event or approval source')
    }
    pumpEvents(socket, feed, approvals, registry, frame.streamId, abort.signal, done)
    return { ok: true }
  }
  if (request.kind === 'control') {
    pumpControl(socket, source, frame.streamId, abort.signal, done)
    return { ok: true }
  }
  if (request.kind === 'workspace') {
    const follow = workspace?.follow
    if (follow === undefined) return refuse('this gateway has no workspace follow source')
    void pumpWorkspace(socket, follow, frame.streamId, abort.signal, done)
    return { ok: true }
  }

  void pumpFollow(socket, source, frame.streamId, request.request, abort.signal, done, openingCapBytes)
  return { ok: true }
}

/** 端点表两种拒绝的句子 —— 码给机器，句子给人，都不关连接。 */
function refusalMessageOf(code: 'unknown-endpoint' | 'invalid-args'): string {
  return code === 'unknown-endpoint'
    ? 'the open frame names no endpoint this gateway serves'
    : 'the open frame args do not fit that endpoint'
}

/**
 * 帧首若干字符，供日志认人。
 *
 * 按 `slice` 截断可能切开一个代理对（末位成孤立代理），这是刻意的：这段文本只进日志，
 * 宁可末位是个问号，也不为它做一套按码点的截断。
 */
function excerptOf(text: string): string {
  return text.length <= EXCERPT_LIMIT ? text : `${text.slice(0, EXCERPT_LIMIT)}…`
}



/**
 * 四条流各自的泵。故障域不同，所以各开一个泵、各订一次源：
 *
 *   session/follow    一个会话的窗口与事件。开流即给整份 `snapshot`。
 *   session/control   投影表。带 `baseline`（每个会话的一次切取），之后按 `seq` 推增量。
 *                    它同时是「标题」「权限当前值」「用量」三类读数的来源 —— 一条投影、
 *                     多个消费者，各自只认自己那一格。
 *   $events           待答集合与宿主通知。`ready` 只说「这一代订阅装好了」，集合本身随后
 *                     整份重放；`emit`（命令/模型/权限目录、登录失效）不重放 —— 它讲的是
 *                     「刚刚发生了什么」，补一条十分钟前的没有意义。
 *   workspace/follow  组清单与归属。带 `baseline`（整份切取），之后七种增量。网关不加工
 *                     任何一个字段：可见性过滤在宿主那一侧。
 *
 * **谁先就绪不连坐**：任一条被拒（源这一代没就绪、装配里没有那个面）只作用于那条流，
 * 连接与别的流不动。`workspace/follow` 缺源时回一条 `internal-error` 而不是静默开流 ——
 * 静默的代价是客户端 45 秒后把**整条连接**判死。
 *
 * **两条带 `baseline` 的流同名不同形**（投影表 vs 组清单），所以客户端的货物解码按流做，
 * 不共用一张全局表；串流来的货物丢弃并留痕，不因此断开连接。
 */




/**
 * 泵一条 follow 流：先打开，再事件，直到源结束、客户端取消、或源破坏
 * 自己的契约。
 */
/**
 * 「某个会话的投影可能变了」的听众，按会话分组。
 *
 * 投影在网关这边是**拉**的：宿主只给 `snapshot(session)`，没有上游那个
 * `sessionProjections.onEventChanged` 订阅口。而真正让投影变化的只有事件
 * （`usageIsTrigger` 那张表），所以 follow 泵遇到那类事件时叫一声，control 泵据此重读。
 * 这样控制流不需要定时器，也不会在空闲时白读。
 *
 * 生命周期跟着 control 泵的 abort 走（`off()` 里连同空集合一起删），漏删的症状是
 * 「占用量停更」—— 与本期要消灭的那个老症状同形，所以注销写成一条路径。
 */
const projectionListeners = new Map<string, Set<(sessionId: string, seq: number) => void>>()

function onProjectionChanged(
  sessionId: string,
  listener: (sessionId: string, seq: number) => void,
): () => void {
  const set = projectionListeners.get(sessionId) ?? new Set<(sessionId: string, seq: number) => void>()
  set.add(listener)
  projectionListeners.set(sessionId, set)
  return () => {
    set.delete(listener)
    if (set.size === 0) projectionListeners.delete(sessionId)
  }
}

/// `'*'` 是通配：基线之后才建的会话也要有人听。
function notifyProjection(sessionId: string, seq: number): void {
  for (const listener of projectionListeners.get(sessionId) ?? []) listener(sessionId, seq)
  for (const listener of projectionListeners.get('*') ?? []) listener(sessionId, seq)
}

/**
 * 两份投影的差 → `changes`。字段名是 `val`，与上游逐字相同 ——
 * 改这一格会让客户端整条控制流解不出。
 */
function controlChangesOf(
  previous: Readonly<Record<string, unknown>>,
  next: Readonly<Record<string, unknown>>,
): { key: string; val: unknown }[] {
  const keys = new Set([...Object.keys(previous), ...Object.keys(next)])
  const changes: { key: string; val: unknown }[] = []
  for (const key of keys) {
    if (JSON.stringify(previous[key]) !== JSON.stringify(next[key])) changes.push({ key, val: next[key] })
  }
  return changes
}

/**
 * `session/control`：**Host-wide** 的投影。打开时给全部会话的基线，之后按会话推增量。
 *
 * 与上游 `SessionControlController` 同形：`baseline.value.projections` 是
 * `{[sessionId]: {asOfSeq, values}}`，增量帧带 `sessionId` 与触发它的 `seq`。
 * 差别只在触发源 —— 上游订阅 `onEventChanged`，我们从 follow 的事件转叫（见上）。
 */
function pumpControl(
  socket: Duplex,
  source: FollowSource,
  streamId: StreamId,
  signal: AbortSignal,
  done: () => void,
): void {
  // 已经取消过：`addEventListener('abort')` 不会补发，所以这里必须先收尾，
  // 否则流表里留一条永不结束的条目。
  if (signal.aborted) {
    done()
    return
  }
  const readAll = source.controlBaseline
  if (readAll === undefined) {
    log.error('control stream opened but the projection face is not wired — refused', { stream: streamId })
    send(socket, {
      type: 'error',
      streamId,
      error: { code: 'internal-error', message: 'this gateway has no projection source', details: {} },
    })
    done()
    return
  }

  // 读失败视作「无话可说」：投影是事件之外的附加物，抛错的读记日志后跳过，
  // 绝不变成会让手机丢掉这条流的 error 帧。
  const read = (): Readonly<Record<string, ProjectionBaseline>> | undefined => {
    try {
      return readAll()
    } catch (error) {
      log.error('projection baseline read failed', { error: describeError(error) })
      return undefined
    }
  }

  let last = read()
  if (last === undefined) {
    log.error('control stream could not read a projection baseline — refused', { stream: streamId })
    send(socket, {
      type: 'error',
      streamId,
      error: { code: 'internal-error', message: 'the projection baseline could not be read', details: {} },
    })
    done()
    return
  }
  send(socket, { type: 'item', streamId, value: { type: 'baseline', value: { projections: last } } satisfies ControlValue })

  // 一个**通配**听众：按会话注册会漏掉「基线之后才建的会话」—— 它不在 `last` 里，
  // 永远没人替它注册。回调带着跳的 `sessionId`，闭包里只重读**它**那一份，代价与按会话
  // 注册相同，覆盖面却是全量。
  const off = onProjectionChanged('*', (sessionId, seq) => {
    const next = read()
    const current = next?.[sessionId]
    if (current === undefined) return
    const previous = last?.[sessionId]
    if (previous !== undefined && current.asOfSeq <= previous.asOfSeq) return
    const changes = controlChangesOf(previous?.values ?? {}, current.values)
    // **只替换该会话那一块**：整表替换会让另一个会话同时变化时拿到被污染的基准。
    last = { ...last, [sessionId]: current }
    if (changes.length === 0) return
    send(socket, {
      type: 'item',
      streamId,
      value: { type: 'projection', sessionId, seq, changes } satisfies ControlValue,
    })
  })

  signal.addEventListener('abort', () => {
    off()
    done()
  }, { once: true })
}

/**
 * `workspace/follow`：宿主给什么就发什么 —— 七种帧一个字段都不动。
 *
 * 网关在这一条上**没有判定**：组清单、归属（`items[].sessionIds`）、归档与置顶两个
 * 集合都由宿主算好，连可见性过滤（`remoteAccess`）也在那一侧。这里只做三件事：
 * 把每帧包成 `item`、把源的失败折成一条 `error`、把中止收成 `end`。
 *
 * 不做增量合并、不缓存上一份：`baseline` 与 `replace` 都是整份替换，客户端按
 * 「后到覆盖」处理。网关存一份就成了第二个状态，而两份状态迟早不一致。
 */
async function pumpWorkspace(
  socket: Duplex,
  follow: NonNullable<WorkspacePort['follow']>,
  streamId: StreamId,
  signal: AbortSignal,
  done: () => void,
): Promise<void> {
  // 已经取消过：`addEventListener('abort')` 不会补发，先收尾。
  if (signal.aborted) {
    done()
    return
  }
  // **取消时不在这里删表**：`done` 会从 `streams` 里摘掉条目，而「取消只停泵、不动表」
  // 是这个通道的不变量（`onClientText` 上那条注释说了为什么：取消即删会让之后同号的
  // `open` 落进空档，而旧泵退出时的收尾删掉的是**新**条目）。条目由 `finally` 在源真的
  // 退出后删 —— 与 `pumpFollow` 同一形态（它也是 async 泵、也只在 finally 里收尾）。
  // 代价是：源若永不响应 `signal`，条目会留着。两害相权取此 —— 留一条已取消的条目只占
  // 一个键，而删错条目会让一条活流关不掉。
  try {
    for await (const frame of follow(signal)) {
      if (signal.aborted) break
      send(socket, { type: 'item', streamId, value: frame })
    }
    if (!signal.aborted) send(socket, { type: 'end', streamId })
  } catch (error) {
    if (!signal.aborted) {
      send(socket, { type: 'error', streamId, error: { ...streamErrorOf(error), details: {} } })
    }
  } finally {
    done()
  }
}

/**
 * `$events` 流：一条流装四种货物 —— `ready`（带 `clientId`）、`emit`（原样转发）、
 * `waterfall` / `cancel`（来自审批中继）。
 *
 * **一条流而不是三条**：上游就是一条，分派在客户端按 `type` 与 `event` 名做。代价写在
 * 拒绝分支上 —— 审批源未就绪时整条流开不起来，`emit` 也跟着没有。上游同样承担这一条
 * （它的 `$events` 源不可用即整条失败），这是合并的固有代价，不是实现缺陷。
 */
function pumpEvents(
  socket: Duplex,
  feed: ForwardedSource,
  approvals: ApprovalSource,
  registry: IdentityRegistry,
  streamId: StreamId,
  signal: AbortSignal,
  done: () => void,
): void {
  // 源这一代没活着就不给集合：给一份「看起来有、其实不知道」的集合比拒绝更坏 ——
  // 客户端会把它当成可信基线，而中继此刻根本不知道上游还挂着什么。
  if (!approvals.ready) {
    log.error('$events opened before the approval relay was ready — refused', { stream: streamId })
    send(socket, {
      type: 'error',
      streamId,
      error: { code: 'source-unavailable', message: 'the forwarded-event source is not ready yet', details: {} },
    })
    done()
    return
  }

  // **每条流一个、换代不变**：换代换的是上游那条流，不是这一条（客户端也只关了上游那条）。
  // 换 id 会让重连那一瞬到达的应答变成越权。
  const clientId = randomUUID()

  // 登记**只做一次**，放在 `announce` 外面：换代只换上游那条流，这条流的 id 与 socket 都没变，
  // 重写那一格没有意义 —— 而 `openStream` 把重入当成「同一 clientId 被两条流复用」并留一条
  // warn，那是给真异常准备的信号，不该被每一代重连灌成噪音（复核 L1）。
  // 先登记、再发 `ready`，两句之间没有 `await`：中间有窗口的话，那段时间里回来的应答
  // 就是「不知道谁答的」。
  registry.openStream(clientId, socket)

  const announce = (): void => {
    const host = feed.host()
    send(socket, {
      type: 'item',
      streamId,
      value: { type: 'ready', clientId, ...(host === undefined ? {} : { host }) } satisfies EventsValue,
    })
    // 每一条 `ready` 后面紧跟一份当前集合 —— 「从这一刻起你看到的都是新的」，
    // 客户端据此把表重建一次，不需要一条单独的「清空」帧。
    for (const held of approvals.held()) {
      send(socket, { type: 'item', streamId, value: waterfallValue(held) })
    }
  }

  const unsubscribe = feed.subscribe({
    generation: () => { announce() },
    frame: (frame) => {
      if (frame.type !== 'emit') return
      // 名字与参数原样转发：这一层不解释上游事件的内容（`api-session/*` 的选择归客户端）。
      send(socket, { type: 'item', streamId, value: { type: 'emit', event: frame.event, args: frame.args } satisfies EventsValue })
    },
  })
  // 先订阅、再发开口帧：两句之间没有 `await`，源不可能插进来一帧。
  announce()
  log.info('$events stream opened', { stream: streamId, client: clientId })

  const offHeld = approvals.onHeld((held) => {
    send(socket, { type: 'item', streamId, value: waterfallValue(held) })
  })
  const offCancelled = approvals.onCancelled((eventId) => {
    send(socket, { type: 'item', streamId, value: { type: 'cancel', eventId } satisfies EventsValue })
  })

  signal.addEventListener('abort', () => {
    unsubscribe()
    offHeld()
    offCancelled()
    // 流关掉，它的 clientId 从此答不了任何问题。与 `openStream` 成对：只登记不注销，
    // 一个已经不在的 clientId 会永远指向一个主人。
    registry.closeStream(clientId)
    done()
  }, { once: true })
}

/** 一条待答调用 → 货物。外壳（`type`）在这里补，中继只给数据。 */
function waterfallValue(held: HeldApproval): MuxApprovalWaterfall {
  return { type: 'waterfall', ...held }
}

/**
 * 泵一条 follow 流：**转达**打开帧，随后转达事件，直到源结束、客户端取消，
 * 或源破坏自己的契约。
 *
 * 网关在这一条上只剩两件事：把字节上界施加在宿主的窗口上（§B1），以及见证
 * 「seq 无缺口」这条源自己的承诺。窗口怎么切、哪些字段随行，都是宿主的判定 ——
 * 上一版在这里按 `maxMessages` 重切一遍，等于把宿主的规则抄了一份，宿主改规则时
 * 网关不会红，症状是「同一屏在 Web UI 与手机上长度不同」。
 *
 * **裁剪只动 `records` 与 `hasMore`**：`cursor` 说的是「宿主覆盖到哪」，不是「我发了
 * 多少」；跟着裁的后果是客户端把「上面还有」读成「日志到头」。
 */
async function pumpFollow(
  socket: Duplex,
  source: FollowSource,
  streamId: StreamId,
  request: FollowRequest,
  signal: AbortSignal,
  done: () => void,
  openingCapBytes: number,
): Promise<void> {
  const sessionId = request.address.sessionId
  const sendItem = (payload: unknown, perf?: PerfContext): void => {
    send(socket, { type: 'item', streamId, value: payload }, perf)
  }

  try {
    // 入参原样交给宿主 —— 包括缺省的键。补一个宿主没要的默认值就是第二份窗口规则。
    const iterable = source.follow(request, signal)

    let expectedSeq: number | undefined // 下一个事件 seq，取自打开的 cursor（含端，故 +1）
    let transientCount = 0

    for await (const frame of iterable) {
      if (signal.aborted) return
      // t1 段终点：上游帧到达网关的时刻。取亚毫秒，于是 t2 的分辨力不受 1 ms 限制。
      const gwRecv = perfNow()

      if (frame.type === 'snapshot') {
        expectedSeq = frame.cursor + 1
        const records = frame.records

        // 帧的组装只写一处：量尺与实际发送共用它 —— 否则「量了什么」与「发了什么」
        // 迟早漂移。`{...frame}` 是转达本身：宿主多给的字段照发，网关不筛。
        const withRecords = (start: number): FollowSnapshot => ({
          ...frame,
          records: records.slice(start),
          hasMore: start > 0 ? true : frame.hasMore,
        })

        // 界由字节定、切点由轮定：装不下就按轮边界收窄，连一轮都装不下则拒绝 ——
        // 「断连」与「发半截轮」都不是可接受的降级。
        const frameBytesAt = (start: number): number =>
          encodeTextFrame(encodeServerFrame({ type: 'item', streamId, value: withRecords(start) })).length
        const shrink = fitOpeningToBytes(records, openingCapBytes, frameBytesAt)
        if ('unshrinkable' in shrink) {
          log.error('follow opening exceeds the cap even at one turn — refused',
            { session: sessionId, cap: openingCapBytes })
          // 拒绝路径没有帧可发，但这条记录就是「这个会话为什么打不开」的答案。
          perfRecord(LogModule.ws, gwRecord({
            sessionId,
            kind: 'opening',
            events: records.length,
            rejected: 'window-too-large',
            gwRecv,
          }, perfNow(), frameBytesAt(0)))
          send(socket, {
            type: 'error',
            streamId,
            error: { code: 'window-too-large', message: 'the most recent turn alone exceeds this connection\'s opening size cap', details: {} },
          })
          return
        }

        const payload = withRecords(shrink.start)
        // 字节数进 info 行（不是只在 perf 记录里）：慢链路上「帧有多大」与「传了多久」
        // 是两件事，而这一行是后者的一半已知量 —— 另一半在客户端。**两半分开报**：
        // 收窄只裁得动 `records`；头部 / 投影基线 / 未定稿基线裁不动，却同样占着上界的
        // 额度 —— 帧超限时，超出的部分可以整个落在这裁不动的一半里。
        const openingBytes = frameBytesAt(shrink.start)
        const fixedBytes = encodeTextFrame(encodeServerFrame({
          type: 'item', streamId, value: { ...frame, records: [] },
        })).length
        log.info('follow opening', {
          session: sessionId,
          cursor: String(payload.cursor),
          events: payload.records.length,
          bytes: openingBytes,
          fixedBytes,
          cutEvents: shrink.cutEvents,
          cutTurns: shrink.cutTurns,
        })
        sendItem(payload, {
          // 窗口重放也占 t2 段，且通常是整条流里最大的一帧 —— 它的尺寸
          // 是「这一帧为什么超限」唯一的现场证据。
          sessionId,
          kind: 'opening',
          events: payload.records.length,
          // 未收窄时这两个字段缺席（不填 0）——「没裁」与「裁了 0 条」是两件事。
          ...(shrink.cutTurns === 0 ? {} : { cutTurns: shrink.cutTurns, cutEvents: shrink.cutEvents }),
          gwRecv,
        })
        continue
      }

      if (frame.type === 'event') {
        const event = frame.event as { type?: unknown; seq?: unknown; time?: unknown } | undefined
        // 源承诺无缺口；我们做见证。跳过的 seq 意味着流自己的承诺破了 ——
        // 高声拒绝，绝不渲染一个谁也看不见的洞。
        if (expectedSeq !== undefined && event?.seq !== expectedSeq) {
          log.error('follow stream broke continuity',
            { expected: String(expectedSeq), got: String(event?.seq) })
          send(socket, { type: 'error', streamId, error: { code: 'internal-error', message: `follow stream skipped seq ${String(expectedSeq)}`, details: {} } })
          return
        }
        if (typeof event?.seq === 'number') expectedSeq = event.seq + 1
        sendItem({ type: 'event', event } satisfies FollowValue, {
          sessionId,
          kind: 'event',
          ...(typeof event?.seq === 'number' ? { seq: event.seq } : {}),
          ...(typeof event?.time === 'number' ? { evTime: event.time } : {}),
          gwRecv,
        }) // 原样 —— 协议消息就是事件对象本身
        // 触发事件可能挪动了投影；确实挪动了才说。
        // 这类事件可能挪动了投影 —— 叫醒同会话的 control 流去重读。控制流自己开着
        // 才有听众，没开时这里是一次空遍历。
        if (typeof event?.type === 'string' && usageIsTrigger({ type: event.type })) {
          notifyProjection(sessionId, typeof event.seq === 'number' ? event.seq : 0)
        }
        continue
      }

      if (frame.type === 'assistant-stream') {
        transientCount += 1
        if (transientCount === 1 || transientCount % 50 === 0) {
          log.info('transient frames forwarded', { count: transientCount })
        }
        sendItem({ type: 'assistant-stream', frame: frame.frame } satisfies FollowValue) // 原样，无 cursor
        continue
      }
    }

    send(socket, { type: 'end', streamId })
  } catch (error) {
    if (!signal.aborted) {
      send(socket, { type: 'error', streamId, error: { ...streamErrorOf(error), details: {} } })
    }
  } finally {
    done()
  }
}
