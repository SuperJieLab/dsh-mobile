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
 * **本文件出现四条错误码，归属各不相同**（`ISSUES` A13 的分类结果）：
 *
 *   window-too-large   传输自有 —— 说的是「这一帧装不下」，由字节上界
 *                      （`StreamOptions.openingCapBytes`）产生，不是会话状态
 *   unknown-op         载荷不是这条流认得的请求 —— 形状判定用 `wire/mux.ts` 的
 *                      `openRequestOf`，这里只决定怎么回：一条带编号的 error 帧，
 *                      **连接与其他流不动**
 *   source-unavailable 事件源在、但这一代还没就绪 —— 给一份「看起来有、其实不知道」
 *                      的待答集合比拒绝更坏，所以拒绝；客户端按可重试处理（传输自有，
 *                      与 `unknown-op` 同族，不进 `protocol/error-codes.ts` 的上游映射）
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
  DEFAULT_FOLLOW_MESSAGES,
  openRequestOf,
  parseClientFrame,
  type FollowOpening,
  type MuxApprovalCancel,
  type MuxApprovalWaterfall,
  type MuxItemFrame,
  type StreamId,
} from '../wire/mux.ts'
import { encodeServerFrame } from '../wire/mux.ts'
import { fitOpeningToBytes, upstreamWindow } from '../protocol/window.ts'
import { usageIsTrigger, usageShouldEmit } from '../protocol/usage.ts'
import { describeError } from '../ports/errors.ts'
import type { ApprovalSource, HeldApproval } from '../ports/approval.ts'
import { streamErrorOf } from '../protocol/error-codes.ts'
import { sessionListChangeOf } from '../upstream/session-events.ts'
import type { WireEvent } from '../wire/rpc.ts'
import type { UsageSnapshot } from '../wire/usage.ts'
import { usageSnapshotOf } from '../upstream/usage.ts'
import type { ModelSelection } from '../wire/model.ts'
import type { FollowSource } from '../ports/follow.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import type { ForwardedSource } from '../ports/events.ts'
import type { Duplex } from 'node:stream'
import { encodeTextFrame } from './frames.ts'
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
 *   - **编号在手**（信封完好）→ 这条流的事：op 认不出就回一条带该编号的 `unknown-op`，
 *     连接与别的流不动。内容坏了不等于这条连接不可信 —— 它还能服务别的流。
 *   - **编号读不出**（不是 JSON、缺 `streamId`、`type` 不认识）→ 无从归流，报
 *     `unreadable-frame`，调用方关连接。
 *
 * `duplicate-id` 同理：同一个编号被第二次 `open`（编号约定不复用）意味着客户端坏了 ——
 * 再在这条连接上服务，每一条流都不可信。静默忽略更糟：客户端会等到 45 秒就绪超时才走，
 * 而那一帧到底发生了什么，两端日志都没有。
 */
/**
 * 从打开帧的投影基线算占用。
 *
 * 缺基线或值不成形时返回 `undefined`，由调用方回落到 `occupancyOf`。两条来源共用
 * `usageSnapshotOf` 这一份换算 —— 分开写，同一个百分比迟早有两个算法。
 */
function occupancyFromBaseline(frame: {
  projections?: { asOfSeq: number; values: Readonly<Record<string, unknown>> }
}): UsageSnapshot | undefined {
  const baseline = frame.projections
  if (baseline === undefined) return undefined
  const reading = usageSnapshotOf(baseline.values, baseline.asOfSeq)
  return reading.usage === undefined ? undefined : reading
}

export function onClientText(
  socket: Duplex,
  source: FollowSource,
  feed: ForwardedSource | undefined,
  approvals: ApprovalSource | undefined,
  streams: Map<StreamId, { abort: AbortController }>,
  text: string,
  openingCapBytes: number,
  /**
   * 会话列表增量行的归属来源。追加在末尾而不是挨着 `approvals`：它是后来才有的
   * 第五个数据源，插在中间会让每个调用点的实参全部错位，而错位的症状是**静默**
   * 的（位置参数，类型又都像）。
   */
  workspace?: WorkspacePort,
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

  const request = openRequestOf(frame.payload)
  if (request === undefined) {
    send(socket, { type: 'error', streamId: frame.streamId, payload: { code: 'unknown-op', message: 'open payload names no stream op this gateway serves' } })
    return { ok: true }
  }

  const abort = new AbortController()
  streams.set(frame.streamId, { abort })
  const done = (): void => { streams.delete(frame.streamId) }

  // 三种连接级流各开各的泵。装配缺了哪一条要的源，就只拒那一条 —— 拒绝要响：静默的
  // 表现是客户端等 45 秒就绪超时，而就绪超时判的是**整条连接**（三条流一起被关）。
  const refuse = (message: string): ClientFrameOutcome => {
    log.error('a connection stream opened but its source is not wired — refused',
      { stream: frame.streamId, op: request.kind })
    streams.delete(frame.streamId)
    send(socket, { type: 'error', streamId: frame.streamId, payload: { code: 'internal-error', message } })
    return { ok: true }
  }

  if (request.kind === 'approvals') {
    if (approvals === undefined) return refuse('this gateway has no approval source')
    pumpApprovals(socket, feed, approvals, frame.streamId, abort.signal, done)
    return { ok: true }
  }
  if (request.kind === 'session-list') {
    if (feed === undefined) return refuse('this gateway has no forwarded-event source')
    pumpSessionList(socket, feed, frame.streamId, abort.signal, done, workspace)
    return { ok: true }
  }
  if (request.kind === 'host-events') {
    if (feed === undefined) return refuse('this gateway has no forwarded-event source')
    pumpHostEvents(socket, feed, frame.streamId, abort.signal, done)
    return { ok: true }
  }

  void pump(socket, source, frame.streamId, request, abort.signal, done, openingCapBytes)
  return { ok: true }
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
 * 一条待答调用 → 这条流上的一帧。
 *
 * 重放与实时**共用这一处**：两处各写一遍时，往一处加字段、另一处忘掉，测试看不出差别
 * （两份代码长得几乎一样），而症状只有重连重放那一次才有。外壳（`streamId` 与 `kind`）
 * 在这里补，中继只给数据。
 */
function waterfallItem(streamId: StreamId, held: HeldApproval): MuxItemFrame {
  // 形状由 `wire/mux.ts` 的声明守：少一个字段在这里就编译不过。
  const payload: MuxApprovalWaterfall = { kind: 'waterfall', ...held }
  return { type: 'item', streamId, payload }
}

/** 一条撤回 → 这条流上的一帧。 */
function cancelItem(streamId: StreamId, eventId: string): MuxItemFrame {
  const payload: MuxApprovalCancel = { kind: 'cancel', eventId }
  return { type: 'item', streamId, payload }
}

/**
 * 三种连接级流各自的泵。三条流的故障域不同，所以各开一个泵、各订一次源：
 *
 *   approvals    只有它会**拒绝开流**（`approvals.ready` 为假时给不出可信集合）。
 *                把它与另外两条绑在一起，等于让最脆的那个决定全体的可用性。
 *   session-list 列表增量。每次都从头建立，靠客户端收到 `ready` 后发一次 list-sessions 追上。
 *   host-events  宿主侧其余通知（命令/模型/权限目录、登录失效）。本期没有客户端订阅者，
 *                但通道要真的通 —— 帧必须挂在流上，`emit` 才有 `streamId` 可带。
 *
 * **开口帧三态**：带集合的就绪（approvals）、只有就绪（session-list / host-events）。
 * 「就绪不建立存在性」这条对后两条成立：`ready` 只说「服务端开好了这条流、源此刻是哪一代」，
 * 客户端要的状态自己另读。
 *
 * **共用一份源**：`ForwardedSource` 是多订阅者，三条流各订一次、各取自己那一类。归属由
 * 适配器判定（`sessionListChangeOf`）—— 认识上游事件名的只有它，泵不认。
 */

/**
 * 审批流：开口即基线。`ready` 之后立刻把此刻还待答的全部重放一遍，随后才是增量。
 *
 * 客户端因此不需要任何「请给我当前集合」的请求 —— 恢复只有一条路径（重开一次流 = 新一份基线）。
 *
 * **开口帧不等源**：订阅那一刻先发一条 `ready`，此后源的每次换代次再发一条。若开口要
 * 等源就绪，一次源的事故会让这条流一直等不到打开帧 —— 而就绪超时判的是**整条连接**。
 * 唯一的例外是**待答集合不可信**（`approvals.ready` 为假）：那时拒绝开流
 * （`source-unavailable`），客户端退避重开。
 *
 * 这条流**不会自己结束**：源断了只发一条无代次的 `ready`，因为结束流会让手机立刻重开
 * 一条注定拿不到正文的流，而重开没有退避。唯一的收场是客户端取消或连接收尾。
 *
 * 两种载荷是它的全部词汇：`ready`（源的状态，`generation` 缺席 = 没有活的代次）与
 * `waterfall` / `cancel`（一条待答调用与它的撤回）。
 */
function pumpApprovals(
  socket: Duplex,
  feed: ForwardedSource | undefined,
  approvals: ApprovalSource,
  streamId: StreamId,
  signal: AbortSignal,
  done: () => void,
): void {
  // 源这一代没活着就不给集合。给一份「看起来有、其实不知道」的集合比拒绝更坏：客户端会
  // 把它当成可信基线，而中继此刻根本不知道上游还挂着什么。拒绝之后客户端按可重试处理、
  // 退避重开 —— 那时源通常已经就绪。
  //
  // 这条拒绝**只落在审批流上**：列表与转发两条流不受影响，这是本期唯一新增的行为。
  if (!approvals.ready) {
    log.error('approvals stream opened before the $events source was ready — refused',
      { stream: streamId })
    send(socket, {
      type: 'error',
      streamId,
      payload: { code: 'source-unavailable', message: 'the forwarded-event source is not ready yet' },
    })
    done()
    return
  }

  const announce = (): void => {
    const generation = feed?.generation
    send(socket, { type: 'item', streamId, payload: { kind: 'ready', ...(generation === undefined ? {} : { generation }) } })
    // 每一条 `ready` 后面紧跟一份当前集合。`ready` 的语义是「从这一刻起你看到的都是新的」，
    // 客户端据此把表重建一次 —— 它不需要一条单独的「清空」帧：没有集契约的帧就没有
    // 「这份名单可信吗」这类要判的事。
    //
    // 集合必须在**中继清空之后**取：中继比本泵先订阅同一份源（装配时构造即订阅），
    // 源的换代通知因此先到中继、后到这里 —— 顺序由订阅序保证，代码里看不出来。
    for (const held of approvals.held()) {
      send(socket, waterfallItem(streamId, held))
    }
  }
  // 只订代次、不订内容：这条流的实时内容来自 `approvals.onHeld`，不是源的帧。
  const unsubscribe = feed?.subscribe({ generation: () => { announce() }, frame: () => {} })
  // 先订阅、再发开口帧：两句之间没有 `await`，源不可能插进来一帧 —— 于是「第一条 item
  // 一定是 ready」与「订阅之后一帧都不漏」同时成立。
  announce()
  // 只记编号：源此刻是哪一代由上游的 `$events ready` 那一条负责（带 `client` 与
  // `generation`）。两处各打一遍的话，同一个 `generation` 在这里指源代次、在流层指
  // 连接代次 —— 同名不同义，而字段名本该是共用词汇表。
  log.info('approvals stream opened', { stream: streamId })

  const offHeld = approvals.onHeld((held) => { send(socket, waterfallItem(streamId, held)) })
  const offCancelled = approvals.onCancelled((eventId) => { send(socket, cancelItem(streamId, eventId)) })

  signal.addEventListener('abort', () => {
    unsubscribe?.()
    offHeld()
    offCancelled()
    done()
  }, { once: true })
}

/**
 * 列表流：只推增量，开口帧只说明「就绪」与「此刻是哪一代」。
 *
 * **没有基线帧，这是刻意的**：列表的恢复走客户端重读（收到 `ready` 发一次 `list-sessions`），
 * 与上游 Web UI 的 `refreshList()` 同一条路。在这里推一份全量要在流上多定义一种帧，
 * 而它换来的只是省一次 HTTP。
 */
function pumpSessionList(
  socket: Duplex,
  feed: ForwardedSource,
  streamId: StreamId,
  signal: AbortSignal,
  done: () => void,
  workspace: WorkspacePort | undefined,
): void {
  const announce = (): void => {
    const generation = feed.generation
    send(socket, { type: 'item', streamId, payload: { kind: 'ready', ...(generation === undefined ? {} : { generation }) } })
  }
  const unsubscribe = feed.subscribe({
    generation: () => { announce() },
    frame: (frame) => {
      if (frame.type !== 'emit') return
      // 归属每次现取一次注册表快照，不缓存：缓存要引入失效时机，而这里错一次就是
      // 一行挂错组。代价是**每一条 emit 帧**都要遍历一次 —— 量级是「工作空间数 ×
      // 成员数」，与事件频率比可以忽略。
      //
      // 判定放在适配器（`sessionListChangeOf`）而不是在这里：认识上游事件名的只有它。
      // 翻不成列表行的那一类不归这条流（见 `pumpHostEvents`）。
      const change = sessionListChangeOf(frame.event, frame.args, workspace?.snapshot().owners)
      if (change === undefined) return
      send(socket, { type: 'item', streamId, payload: { kind: 'session-list', change } })
    },
  })
  announce()
  log.info('session-list stream opened', { stream: streamId })

  signal.addEventListener('abort', () => {
    unsubscribe()
    done()
  }, { once: true })
}

/**
 * 宿主通知流：上游 `emit` 的原样转发，只排除属于列表的那几类。
 *
 * **本期没有客户端订阅者**（`ISSUES` C66）。它存在是因为帧必须挂在流上：`emit` 若有
 * 转发的必要，就必然有一条流可挂。删除这条流等于把 `commands/change`、模型目录、
 * 登录失效四条路一起删掉。
 *
 * 「是不是列表那几类」仍由适配器答：这里调 `sessionListChangeOf` 只是为了排除，不看它
 * 的返回值内容。代价写清 —— 一条载荷畸形、翻不成列表行的 `api-session/*` 事件会落到
 * 这条流上（多转一帧没人读的内容，不会串到列表那条）。
 */
function pumpHostEvents(
  socket: Duplex,
  feed: ForwardedSource,
  streamId: StreamId,
  signal: AbortSignal,
  done: () => void,
): void {
  const announce = (): void => {
    const generation = feed.generation
    send(socket, { type: 'item', streamId, payload: { kind: 'ready', ...(generation === undefined ? {} : { generation }) } })
  }
  const unsubscribe = feed.subscribe({
    generation: () => { announce() },
    frame: (frame) => {
      if (frame.type !== 'emit') return
      if (sessionListChangeOf(frame.event, frame.args) !== undefined) return
      // 名字与参数原样转发：这一层不解释上游事件的内容。
      send(socket, { type: 'item', streamId, payload: { kind: 'emit', event: frame.event, args: frame.args } })
    },
  })
  announce()
  log.info('host-events stream opened', { stream: streamId })

  signal.addEventListener('abort', () => {
    unsubscribe()
    done()
  }, { once: true })
}

/**
 * 泵一条 follow 流：先打开，再事件，直到源结束、客户端取消、或源破坏
 * 自己的契约。
 */
async function pump(
  socket: Duplex,
  source: FollowSource,
  streamId: StreamId,
  request: { sessionId: string; maxMessages?: number },
  signal: AbortSignal,
  done: () => void,
  openingCapBytes: number,
): Promise<void> {
  const sendItem = (payload: unknown, perf?: PerfContext): void => {
    send(socket, { type: 'item', streamId, payload }, perf)
  }

  /**
   * 读占用投影，把读失败视作「无话可说」：占用是事件之外的附加物，
   * 抛错的读记日志后跳过，绝不变成会让手机失去会话的 `error` 帧。
   */
  const readUsage = (): UsageSnapshot | undefined => {
    try {
      return source.occupancyOf(request.sessionId)
    } catch (error) {
      log.error('occupancy read failed',
        { session: request.sessionId, error: describeError(error) })
      return undefined
    }
  }

  /**
   * 读模型基线，规则同占用：事件之外的附加物，抛错的读记日志后
   * 跳过，绝不是 `error` 帧。
   */
  const readModel = (): ModelSelection | undefined => {
    if (source.modelOf === undefined) return undefined
    try {
      return source.modelOf(request.sessionId)
    } catch (error) {
      log.error('model read failed',
        { session: request.sessionId, error: describeError(error) })
      return undefined
    }
  }

  /** 本流上一条已发送的读数 —— 基线算数，因此不重发。 */  let lastUsage: UsageSnapshot | undefined
  const pushUsage = (): void => {
    const reading = readUsage()
    if (reading === undefined || !usageShouldEmit(lastUsage, reading)) return
    lastUsage = reading
    send(socket, { type: 'usage', streamId, payload: { sessionId: request.sessionId, ...reading } })
  }

  try {
    const iterable = source.follow({
      address: { kind: 'session', sessionId: request.sessionId },
      // 窗口按参考的拼法请求，切自我们 `page` 窗口所用的同一目标 ——
      // 打开因此始于 turn 边界。
      ...upstreamWindow(request.maxMessages ?? DEFAULT_FOLLOW_MESSAGES),
      assistantStream: true,
      // 与上游浏览器客户端同一条路：打开即激活。少了它，这个会话在宿主里只被被动观察，
      // `ctx.agents` 里没有它 —— 手机上看着一切正常，一发消息就是「会话不在」。
      activate: true,
    }, signal)

    let expectedSeq: number | undefined // 下一个事件 seq，取自打开的 cursor
    let transientCount = 0

    for await (const frame of iterable) {
      if (signal.aborted) return
      // t1 段终点：上游帧到达网关的时刻。取亚毫秒，于是 t2 的分辨力不受 1 ms 限制。
      const gwRecv = perfNow()

      if (frame.type === 'snapshot') {
        // 窗口已由源自身的分页切好 —— 与 `page` 建模所依据的是同一条
        // 消息数规则。解包即可，不要重切。
        //
        // `record.event` 在宿主侧是不透明的，这里把它标成 `WireEvent` 是
        // **转发契约的断言**（协议 §4.1 承诺 `{type, seq, time, data}`，我们
        // 原样转达、不解语义）。不标它，opening 的类型就拴不住实际发出的字段。
        const events = frame.records.map(record => record.event as WireEvent)
        const cursor = frame.cursor + 1 // 参考 cursor 含端；我们排他
        expectedSeq = cursor
        // 占用基数优先取自**这一帧自带的投影基线**：它与窗口出自同一次观察（同一
        // `asOfSeq`）。`occupancyOf` 要经 `sessions.get`，那条路要一个已加载的会话
        // 对象 —— 未激活的历史会话拿不到，整份占用会静默缺省；而投影其实已经送来。
        const occupancy = occupancyFromBaseline(frame) ?? readUsage()
        lastUsage = occupancy
        const model = readModel()

        // 窗口的组装只写一处：量尺与实际发送共用它 —— 否则「量了什么」
        // 与「发了什么」迟早漂移。返回类型钉成 `FollowOpening`：加字段忘了
        // 改类型、或把错形状塞进某个字段，都在编译期失败（本期 `model` 就是
        // 这么漏了两版）。
        const openingPayload = (start: number): FollowOpening => {
          const kept = events.slice(start)
          const first = kept[0] as { seq?: unknown } | undefined
          return {
            sessionId: request.sessionId,
            cursor,
            pageStart: typeof first?.seq === 'number' ? first.seq : cursor,
            hasOlder: start > 0 || frame.hasMore,
            events: kept,
            ...(frame.assistantStream === undefined ? {} : { assistantStream: frame.assistantStream }),
            ...(occupancy === undefined ? {} : { occupancy }),
            ...(model === undefined ? {} : { model }),
          }
        }

        // 界由字节定、切点由轮定：装不下就按轮边界收窄，连一轮都装不下则拒绝 ——
        // 「断连」与「发半截轮」都不是可接受的降级。
        const frameBytesAt = (start: number): number =>
          encodeTextFrame(encodeServerFrame({ type: 'item', streamId, payload: openingPayload(start) })).length
        const shrink = fitOpeningToBytes(events, openingCapBytes, frameBytesAt)
        if ('unshrinkable' in shrink) {
          log.error('follow opening exceeds the cap even at one turn — refused',
            { session: request.sessionId, cap: openingCapBytes })
          // 拒绝路径没有帧可发，但这条记录就是「这个会话为什么打不开」的答案。
          perfRecord(LogModule.ws, gwRecord({
            sessionId: request.sessionId,
            kind: 'opening',
            events: events.length,
            rejected: 'window-too-large',
            gwRecv,
          }, perfNow(), frameBytesAt(0)))
          send(socket, {
            type: 'error',
            streamId,
            payload: { code: 'window-too-large', message: 'the most recent turn alone exceeds this connection\'s opening size cap' },
          })
          return
        }

        const sentCount = events.length - shrink.start
        // 字节数进 info 行（不是只在 perf 记录里）：慢链路上「帧有多大」与「传了多久」
        // 是两件事，而这一行是后者的一半已知量 —— 另一半在客户端。**两半分开报**：
        // 收窄只裁得动 `events`；未定稿基线 / 占用 / 模型基线裁不动，却同样占着上界的
        // 额度 —— 帧超限时，超出的部分可以整个落在这裁不动的一半里。
        const openingBytes = frameBytesAt(shrink.start)
        const fixedBytes = encodeTextFrame(encodeServerFrame({
          type: 'item', streamId, payload: { ...openingPayload(shrink.start), events: [] },
        })).length
        log.info('follow opening', {
          session: request.sessionId,
          cursor: String(cursor),
          events: sentCount,
          bytes: openingBytes,
          fixedBytes,
          cutEvents: shrink.cutEvents,
          cutTurns: shrink.cutTurns,
        })
        sendItem(openingPayload(shrink.start), {
          // 窗口重放也占 t2 段，且通常是整条流里最大的一帧 —— 它的尺寸
          // 是「这一帧为什么超限」唯一的现场证据。
          sessionId: request.sessionId,
          kind: 'opening',
          events: sentCount,
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
          send(socket, { type: 'error', streamId, payload: { code: 'internal-error', message: `follow stream skipped seq ${String(expectedSeq)}` } })
          return
        }
        if (typeof event?.seq === 'number') expectedSeq = event.seq + 1
        sendItem(event, {
          sessionId: request.sessionId,
          kind: 'event',
          ...(typeof event?.seq === 'number' ? { seq: event.seq } : {}),
          ...(typeof event?.time === 'number' ? { evTime: event.time } : {}),
          gwRecv,
        }) // 原样 —— 协议消息就是事件对象本身
        // 触发事件可能挪动了投影；确实挪动了才说。
        if (typeof event?.type === 'string' && usageIsTrigger({ type: event.type })) pushUsage()
        continue
      }

      if (frame.type === 'assistant-stream') {
        transientCount += 1
        if (transientCount === 1 || transientCount % 50 === 0) {
          log.info('transient frames forwarded', { count: transientCount })
        }
        sendItem({ type: 'assistant-stream', frame: frame.frame }) // 原样，无 cursor
        continue
      }
    }

    send(socket, { type: 'end', streamId })
  } catch (error) {
    if (!signal.aborted) {
      send(socket, { type: 'error', streamId, payload: streamErrorOf(error) })
    }
  } finally {
    done()
  }
}
