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
  type MuxApprovalWaterfall,
  type StreamId,
} from '../wire/mux.ts'
import { encodeServerFrame } from '../wire/mux.ts'
import { fitOpeningToBytes, upstreamWindow } from '../protocol/window.ts'
import { usageIsTrigger, usageShouldEmit } from '../protocol/usage.ts'
import { randomUUID } from 'node:crypto'
import { describeError } from '../ports/errors.ts'
import type { ApprovalSource, HeldApproval } from '../ports/approval.ts'
import { streamErrorOf } from '../protocol/error-codes.ts'
import type { WireEvent } from '../wire/rpc.ts'
import type { UsageSnapshot } from '../wire/usage.ts'
import { usageSnapshotOf } from '../upstream/usage.ts'
import type { ModelSelection } from '../wire/model.ts'
import type { FollowSource } from '../ports/follow.ts'
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
    pumpEvents(socket, feed, approvals, frame.streamId, abort.signal, done)
    return { ok: true }
  }
  if (request.kind === 'control') {
    return refuse('this gateway has no projection source yet')
  }

  void pump(socket, source, frame.streamId, request, abort.signal, done, openingCapBytes)
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
 * 泵一条 follow 流：先打开，再事件，直到源结束、客户端取消、或源破坏
 * 自己的契约。
 */
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

  const clientId = randomUUID()

  const announce = (): void => {
    send(socket, { type: 'item', streamId, value: { type: 'ready', clientId } })
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
      send(socket, { type: 'item', streamId, value: { type: 'emit', event: frame.event, args: frame.args } })
    },
  })
  // 先订阅、再发开口帧：两句之间没有 `await`，源不可能插进来一帧。
  announce()
  log.info('$events stream opened', { stream: streamId, client: clientId })

  const offHeld = approvals.onHeld((held) => {
    send(socket, { type: 'item', streamId, value: waterfallValue(held) })
  })
  const offCancelled = approvals.onCancelled((eventId) => {
    send(socket, { type: 'item', streamId, value: { type: 'cancel', eventId } })
  })

  signal.addEventListener('abort', () => {
    unsubscribe()
    offHeld()
    offCancelled()
    done()
  }, { once: true })
}

/** 一条待答调用 → 货物。外壳（`type`）在这里补，中继只给数据。 */
function waterfallValue(held: HeldApproval): MuxApprovalWaterfall {
  return { type: 'waterfall', ...held }
}

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
    send(socket, { type: 'item', streamId, value: payload }, perf)
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
          encodeTextFrame(encodeServerFrame({ type: 'item', streamId, value: openingPayload(start) })).length
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
            error: { code: 'window-too-large', message: 'the most recent turn alone exceeds this connection\'s opening size cap', details: {} },
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
          type: 'item', streamId, value: { ...openingPayload(shrink.start), events: [] },
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
          send(socket, { type: 'error', streamId, error: { code: 'internal-error', message: `follow stream skipped seq ${String(expectedSeq)}`, details: {} } })
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
      send(socket, { type: 'error', streamId, error: { ...streamErrorOf(error), details: {} } })
    }
  } finally {
    done()
  }
}
