/**
 * 流适配器：自有监听器上的 WebSocket 升级，以及把会话控制器的 follow 流
 * 泵成 mux 帧的泵。
 *
 * 升级挂在插件自己启动的监听器上（`'upgrade'`，与 `POST /rpc` 同端口）——
 * `ctx.webServer` 是宿主全局的，其 CLI 拒绝 `0.0.0.0`，网关因此自带监听
 * （M0 §3.2）。
 *
 * 泵对线上的承诺（M2 §3.3，
 * §3.2/§4.4 step 3）：参考的 `{type:'event', event}` 包裹解包；打开的窗口
 * 已由源分页切好（其含端 cursor 变成我们的排他 cursor）；事件与无 cursor
 * 的 transient 帧**原样**通行。适配器只补传输欠下的：成帧、心跳、
 * seq 连续性见证（源承诺无缺口；它说谎时我们高声拒绝）与
 * 错误映射。
 */

import type { Duplex, IncomingMessage, Server } from 'node:http'
import {
  DEFAULT_FOLLOW_MESSAGES,
  encodeServerFrame,
  followRequestOf,
  parseClientFrame,
  type MuxServerFrame,
} from '../contract/mux.ts'
import { fitOpeningToBytes, upstreamWindow } from '../contract/window.ts'
import { DEFAULT_LIMITS, positiveOrDefault } from '../contract/rpc.ts'
import { describeError, isNotFound, isUnreadable } from '../contract/errors.ts'
import { usageIsTrigger, usageShouldEmit, type UsageSnapshot } from '../contract/usage.ts'
import {
  WsFrameParser,
  acceptKeyOf,
  encodeClose,
  encodePing,
  encodePong,
  encodeTextFrame,
  handshakeResponse,
} from '../contract/ws-frames.ts'
import { createLogger, LogModule, perfRecord } from '../log.ts'

const log = createLogger(LogModule.ws)

/**
 * 泵所用的宿主窄面，在此声明是因为各服务的真实类型在 dsh 安装树之外
 * 无法解析。follow 流与占用读数作为一次注入到达，因为两者出自同一宿主
 * （M6 §四）。
 */
export interface FollowSource {
  follow(
    request: {
      address: { kind: 'session'; sessionId: string }
      maxMessages?: number
      /**
       * 参考拼法的边界规则：一个可提前停下的下限与一个必须停下的上限
       * （见 `upstreamWindow`）。缺省即宿主仅按消息数切窗，窗口会在
       * 一轮中间打开。
       */
      turnWindow?: { minMessages: number; minTurns: number }
      assistantStream: true
    },
    signal: AbortSignal,
  ): AsyncIterable<UpstreamFollowFrame>
  /**
   * 立即读取一个会话的占用投影 —— 同步、内存内：宿主在事件落地时折叠
   * 投影，所以这是状态读，不是日志走查
   * （M6 §3.1 决定 3）。
   *
   * @returns 读数；宿主不知道该会话时 `undefined`。
   */
  occupancyOf(sessionId: string): UsageSnapshot | undefined

  /**
   * 会话的模型基线：`modelSelection` 投影的线上视图，未知时 undefined。
   * 与窗口同一口气读出，手机打开时即知下一个请求用什么 —— HTTP snapshot
   * 带同一字段，但活会话实际走的是 follow 打开这条路。
   */
  modelOf?(sessionId: string): unknown
}

/**
 * 参考 follow 流的一帧，形状已在 `0d1f5000` 验证（`history.ts:119-240`）：
 * 打开的 `snapshot`，其 `records` 把每条事件包成 `{type:'event', event}`；
 * 随后是同包裹的 `event` 帧；再后是无 cursor 的 `assistant-stream` 帧。
 */
export type UpstreamFollowFrame =
  | {
      type: 'snapshot'
      /** 打开覆盖的最后一个 seq，含端；空日志为 `-1`。 */
      cursor: number
      records: readonly { type: 'event'; event: unknown }[]
      /** 窗口之前是否还有更旧的事件（参考的 `hasMore`）。 */
      hasMore: boolean
      assistantStream?: unknown
    }
  | { type: 'event'; event: unknown }
  | { type: 'assistant-stream'; frame: unknown }

/** 心跳节拍，对齐参考服务端。 */
const PING_INTERVAL_MS = 2_000

/** 连续多少个 pong 未回即视为客户端已消失。 */
const MISSED_PONG_LIMIT = 2

/**
 * 一条帧过 send 边界时携带的计时上下文（R8 期1 链路 A）—— pump 在循环里
 * 取 gwRecv（上游帧到达），send 在写出前补 gwSend 与字节数，合成一条 gw
 * 记录。窗口重放（opening）与事件帧同占这一段，故两者都走这条路：
 * opening 是单帧尺寸的最大来源，漏记它等于把要测的那条漏掉。
 * 缺的字段（seq / evTime / events）原样缺席，不填默认值。
 */
interface PerfContext {
  readonly sessionId: string
  /** 帧的子类 —— 判读按它，不按「`seq` 缺席」（缺席当判据是脆的）。 */
  readonly kind: 'opening' | 'event'
  readonly seq?: number
  readonly evTime?: number
  /** 仅 opening：本条窗口携带的事件数，与 `bytes` 并读即得窗口形状。 */
  readonly events?: number
  /** 仅收窄过的 opening：被裁掉的轮数与事件数。未收窄时**缺席**，不填 0。 */
  readonly cutTurns?: number
  readonly cutEvents?: number
  /** 仅被拒绝的 opening：无帧可发，这里记原因（值为错误码）。 */
  readonly rejected?: string
  readonly gwRecv: number
}

/**
 * 一条 gw 记录的字段组装 —— 发送路径与拒绝路径共用它。拒绝时没有帧，但那条
 * 记录恰恰是「这个会话为什么打不开」的唯一答案，所以两处的字段集不能各写一遍。
 */
function gwRecord(perf: PerfContext, gwSend: number, bytes: number): Record<string, unknown> {
  return {
    seg: 'gw',
    t: gwSend,
    sessionId: perf.sessionId,
    kind: perf.kind,
    ...(perf.seq === undefined ? {} : { seq: perf.seq }),
    ...(perf.evTime === undefined ? {} : { evTime: perf.evTime }),
    ...(perf.events === undefined ? {} : { events: perf.events }),
    ...(perf.cutTurns === undefined ? {} : { cutTurns: perf.cutTurns }),
    ...(perf.cutEvents === undefined ? {} : { cutEvents: perf.cutEvents }),
    ...(perf.rejected === undefined ? {} : { rejected: perf.rejected }),
    gwRecv: perf.gwRecv,
    gwSend,
    bytes,
  }
}

/** 本网关提供流协议的精确路径。 */
export const STREAM_PATH = '/rpc/stream'

/** approval 中继向已连接手机推送所用的接口。 */
export interface Broadcaster {
  /** 向每个存活且已认证的客户端发送一条连接级帧。 */
  broadcast(frame: MuxServerFrame): void
  /** 当前接入的客户端数 —— 资源采样读它（R8 期1 链路 B）。 */
  clientCount(): number
}

/** 每个接入的客户端调用一次，附带限定于该 socket 的发送器。 */
export type ClientHook = (send: (frame: MuxServerFrame) => void) => void

/**
 * 打开帧的默认字节上界（R9 期1）—— 与 HTTP 路径的上限同处一族，定义在
 * `contract/rpc.ts` 的 `DEFAULT_LIMITS`（那里有取值来由）。做成可传参而非常量，
 * 理由与 `maxDeltaEvents` 相同：让收窄路径**可被端到端观测**（调到极小值就能
 * 看见它发生），而不是只活在文档里。
 */
export const DEFAULT_OPENING_BYTES = DEFAULT_LIMITS.maxOpeningBytes

/** 流适配器的可调项。 */
export interface StreamOptions {
  /** 每个接入的客户端调用一次，附带限定于该 socket 的发送器。 */
  onClientConnected?: ClientHook
  /** 打开帧的字节上界；缺省即 {@link DEFAULT_OPENING_BYTES}。 */
  openingCapBytes?: number
}

/**
 * 把流协议挂上插件自己的监听器：处理器接管协商（对照握手 key 验证）与
 * 其后的 socket；socket 错误被吞掉 —— 客户端死亡是常态。
 *
 * `gate` 是认证闸门，在应答握手之前于升级时检查一次 —— 无有效
 * access token，就没有 101。token 过期后连接继续存活；重新认证发生在
 * 下一次连接，不在流中途（M4 §3.3）。
 */
export function attachStreamHandler(
  server: Server,
  source: FollowSource,
  gate: { authenticate(authorizationHeader: string | undefined): boolean },
  options: StreamOptions = {},
): Broadcaster {
  const clients = new Set<Duplex>()
  server.on('upgrade', (request, socket, head) => {
    void handleUpgrade(request, socket, head, source, gate, clients, options)
  })
  return {
    broadcast(frame) {
      const text = encodeTextFrame(encodeServerFrame(frame))
      for (const socket of clients) write(socket, text)
    },
    clientCount: () => clients.size,
  }
}

async function handleUpgrade(
  request: IncomingMessage,
  socket: Duplex,
  head: Buffer,
  source: FollowSource,
  gate: { authenticate(authorizationHeader: string | undefined): boolean },
  clients: Set<Duplex>,
  options: StreamOptions,
): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://gateway').pathname
  log.info(`upgrade request for "${path}"`)
  if (path !== STREAM_PATH) {
    // 不是我们的路径 —— 直接拒绝，不假装会说 WebSocket。
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n')
    socket.destroy()
    return
  }

  if (!gate.authenticate(request.headers.authorization)) {
    log.info('upgrade refused: no valid access token')
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n')
    socket.destroy()
    return
  }

  const accept = acceptKeyOf(request.headers)
  if (accept === undefined) {
    log.info('upgrade refused: no Sec-WebSocket-Key')
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n')
    socket.destroy()
    return
  }

  log.info('upgrade accepted → 101')
  socket.write(handshakeResponse(accept))
  clients.add(socket)
  perfRecord(LogModule.ws, { seg: 'gw', t: Date.now(), conn: 'upgrade-accepted' })
  socket.on('close', () => clients.delete(socket))
  runSocket(socket, source, head, options)
  // 在客户端开口之前，重放当前挂起之物（持有的 approval）。
  options.onClientConnected?.((frame) => send(socket, frame))
}

/** 每连接的状态与循环。 */
function runSocket(socket: Duplex, source: FollowSource, head: Buffer, options: StreamOptions): void {
  const parser = new WsFrameParser()
  // 非正的上界会让每次打开都被判成「装不下」—— 归一化规则与 HTTP 路径共享
  // 同一实现（`positiveOrDefault`），不在这里重写一遍。
  const openingCapBytes = positiveOrDefault(options.openingCapBytes, DEFAULT_OPENING_BYTES)
  const streams = new Map<number, { abort: AbortController }>()

  // 参考服务端用同样的预算断连（`stream-server.ts`）。
  let unansweredPings = 0
  const heartbeat = setInterval(() => {
    unansweredPings += 1
    if (unansweredPings > MISSED_PONG_LIMIT) {
      socket.destroy()
      return
    }
    write(socket, encodePing())
  }, PING_INTERVAL_MS)

  const closeAll = (): void => {
    clearInterval(heartbeat)
    for (const stream of streams.values()) stream.abort.abort()
    streams.clear()
  }

  const onChunk = (chunk: Buffer): void => {
    const { frames, error } = parser.push(chunk)
    if (error !== undefined) {
      // 破坏成帧的对端说的不是这个协议；没有帧可发，也没有流可指。
      // 关闭。
      socket.destroy()
      return
    }
    for (const frame of frames) {
      switch (frame.kind) {
        case 'pong':
          unansweredPings = 0
          break
        case 'ping':
          write(socket, encodePong(frame.payload))
          break
        case 'close':
          write(socket, encodeClose())
          socket.end()
          break
        case 'text':
          onClientText(socket, source, streams, frame.text, openingCapBytes)
          break
      }
    }
  }

  // 帧可能搭在升级请求的最后字节里。
  if (head.length > 0) onChunk(head)
  socket.on('data', onChunk)
  socket.on('close', closeAll)
  socket.on('error', closeAll)
}

/**
 * 路由一条解析好的客户端文本帧：`open` 起泵，`cancel` 停泵。契约的
 * 解析器已拒掉畸形帧，活下来的都过了形状检查。
 */
function onClientText(
  socket: Duplex,
  source: FollowSource,
  streams: Map<number, { abort: AbortController }>,
  text: string,
  openingCapBytes: number,
): void {
  const frame = parseClientFrame(text)
  if (frame === undefined) return

  if (frame.type === 'cancel') {
    const stream = streams.get(frame.streamId)
    if (stream !== undefined) {
      stream.abort.abort()
      streams.delete(frame.streamId)
    }
    return
  }

  // 以下是 frame.type === 'open'
  if (streams.has(frame.streamId)) return // 占用中的 id 不重开；id 归客户端所有

  const request = followRequestOf(frame.payload)
  if (request === undefined) {
    send(socket, { type: 'error', streamId: frame.streamId, payload: { code: 'unknown-op', message: 'open payload is not a follow request' } })
    return
  }

  const abort = new AbortController()
  streams.set(frame.streamId, { abort })
  void pump(socket, source, frame.streamId, request, abort.signal, () => streams.delete(frame.streamId), openingCapBytes)
}

/**
 * 泵一条 follow 流：先打开，再事件，直到源结束、客户端取消、或源破坏
 * 自己的契约。
 */
async function pump(
  socket: Duplex,
  source: FollowSource,
  streamId: number,
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
      log.error(`occupancy read failed for "${request.sessionId}": ${describeError(error)}`)
      return undefined
    }
  }

  /**
   * 读模型基线，规则同占用：事件之外的附加物，抛错的读记日志后
   * 跳过，绝不是 `error` 帧。
   */
  const readModel = (): unknown => {
    if (source.modelOf === undefined) return undefined
    try {
      return source.modelOf(request.sessionId)
    } catch (error) {
      log.error(`model read failed for "${request.sessionId}": ${describeError(error)}`)
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
    }, signal)

    let expectedSeq: number | undefined // 下一个事件 seq，取自打开的 cursor
    let transientCount = 0

    for await (const frame of iterable) {
      if (signal.aborted) return
      // R8 期1：t1 段终点 —— 上游帧到达网关的时刻（与 harness 同机同时钟）。
      const gwRecv = Date.now()

      if (frame.type === 'snapshot') {
        // 窗口已由源自身的分页切好 —— 与 `page` 建模所依据的是同一条
        // 消息数规则。解包即可，不要重切。
        const events = frame.records.map(record => record.event)
        const cursor = frame.cursor + 1 // 参考 cursor 含端；我们排他
        expectedSeq = cursor
        // 占用基线与窗口同一口气读出：手机打开时拿到的是同一时刻的
        // 窗口与状态。
        const occupancy = readUsage()
        lastUsage = occupancy
        const model = readModel()

        // 窗口的组装只写一处：量尺与实际发送共用它 —— 否则「量了什么」
        // 与「发了什么」迟早漂移。
        const openingPayload = (start: number): Record<string, unknown> => {
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

        // 界由字节定、切点由轮定（R9 期1）：装不下就按轮边界收窄，连一轮
        // 都装不下则拒绝 —— 「断连」与「发半截轮」都不是可接受的降级。
        const frameBytesAt = (start: number): number =>
          encodeTextFrame(encodeServerFrame({ type: 'item', streamId, payload: openingPayload(start) })).length
        const shrink = fitOpeningToBytes(events, openingCapBytes, frameBytesAt)
        if ('unshrinkable' in shrink) {
          log.error(`follow opening for "${request.sessionId}" exceeds the ${openingCapBytes}-byte cap even at one turn — refused`)
          // 拒绝路径没有帧可发，但这条记录就是「这个会话为什么打不开」的答案。
          perfRecord(LogModule.ws, gwRecord({
            sessionId: request.sessionId,
            kind: 'opening',
            events: events.length,
            rejected: 'window-too-large',
            gwRecv,
          }, Date.now(), frameBytesAt(0)))
          send(socket, {
            type: 'error',
            streamId,
            payload: { code: 'window-too-large', message: 'the most recent turn alone exceeds this connection\'s opening size cap' },
          })
          return
        }

        const sentCount = events.length - shrink.start
        log.info(`follow opening for "${request.sessionId}": cursor=${cursor}, ${sentCount} events`
          + (shrink.cutEvents === 0 ? '' : ` (narrowed by ${shrink.cutEvents} events / ${shrink.cutTurns} turns)`))
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
        // 高声拒绝，绝不渲染一个谁也看不见的洞
        // （M2 §3.5）。
        if (expectedSeq !== undefined && event?.seq !== expectedSeq) {
          log.error(`follow stream broke continuity: expected seq ${String(expectedSeq)}, got ${String(event?.seq)}`)
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
          log.info(`transient frames forwarded: ${transientCount}`)
        }
        sendItem({ type: 'assistant-stream', frame: frame.frame }) // 原样，无 cursor
        continue
      }
    }

    send(socket, { type: 'end', streamId })
  } catch (error) {
    if (!signal.aborted) {
      send(socket, { type: 'error', streamId, payload: mapError(error) })
    }
  } finally {
    done()
  }
}

/**
 * 把源的失败映射到协议的错误对象，错误码与 HTTP 路径一致：不可解读的日志
 * 是 `unreadable-session`，源不认识的会话是 `unknown-session`，其余是
 * `internal-error`。
 */
function mapError(error: unknown): { code: string; message: string } {
  if (isUnreadable(error)) {
    return { code: 'unreadable-session', message: describeError(error) }
  }
  // 本通道所读的一切都按会话寻址，not-found 就是会话的；谓词与写路径
  // 共享，两者因此不会漂移。
  if (isNotFound(error)) {
    return { code: 'unknown-session', message: describeError(error) }
  }
  return { code: 'internal-error', message: describeError(error) }
}

function send(socket: Duplex, frame: MuxServerFrame, perf?: PerfContext): void {
  const frameBytes = encodeTextFrame(encodeServerFrame(frame))
  if (perf !== undefined) {
    // t2 段终点 = 写出时刻。t 与 gwSend 同值有意重复一次：消费方不必记
    // 「t 对 gw 记录意味着什么」这个约定。
    const gwSend = Date.now()
    perfRecord(LogModule.ws, gwRecord(perf, gwSend, frameBytes.length))
  }
  write(socket, frameBytes)
}

function write(socket: Duplex, buffer: Buffer): void {
  if (socket.destroyed) return
  socket.write(buffer)
}
