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
  type FollowOpening,
  type MuxServerFrame,
} from '../contract/mux.ts'
import { fitOpeningToBytes, upstreamWindow } from '../contract/window.ts'
import { DEFAULT_LIMITS, positiveOrDefault } from '../contract/rpc.ts'
import type { WireEvent } from '../contract/rpc.ts'
import { describeError, isNotFound, isUnreadable } from '../contract/errors.ts'
import { usageIsTrigger, usageShouldEmit, type UsageSnapshot } from '../contract/usage.ts'
import type { ModelSelection } from '../contract/model-selection.ts'
import {
  WsFrameParser,
  acceptKeyOf,
  encodeClose,
  encodePing,
  encodePong,
  encodeTextFrame,
  handshakeResponse,
} from '../contract/ws-frames.ts'
import { createLogger, LogModule, perfNow, perfRecord } from '../log.ts'

const log = createLogger(LogModule.ws)

// 端口与上游帧形状已搬到装配边界 `ports/follow.ts` —— 面向宿主的适配层要的是这个
// 接口，让它从传输层取就是反向依赖。这里 import 再用并重导出，下游路径不必一次改完。
import type { FollowSource, UpstreamFollowFrame } from '../ports/follow.ts'
export type { FollowSource, UpstreamFollowFrame } from '../ports/follow.ts'

/** 心跳节拍，对齐参考服务端。 */
const PING_INTERVAL_MS = 2_000

/** 连续多少个 pong 未回即视为客户端已消失。 */
const MISSED_PONG_LIMIT = 2

/**
 * 心跳所要的 socket 窄面 —— 只取它读的那几样。做成窄面是为了让**这条规则本身**
 * 可以脱离真 socket 被断言（写不出去的 socket 只能靠一只假 socket 复现）。
 */
export interface HeartbeatSocket {
  /** 还在排队、尚未落盘的字节数。大于 0 = 这一拍我们自己的 ping 也排在那队后面。 */
  readonly writableLength: number
  readonly destroyed: boolean
  destroy(): void
  write(buffer: Buffer): unknown
}

/** 一段连接的心跳句柄。 */
export interface Heartbeat {
  /**
   * 收到对端的**任何一帧**：连失数归零。不只认 pong —— 客户端每 2 秒一次的 ping 走的是
   * **未被堵住**的方向（客户端 → 网关），它同样证明客户端在看；而我们的 pong 可能正排在一大帧
   * 后面（来由见 `startHeartbeat`）。
   */
  heardFrame(): void
  /** 停拍（连接收尾时调用）。 */
  stop(): void
  /**
   * 这条连接是不是**被这一拍掐掉的**（而不是对端自己走的）。用来让「连接结束」那行说出
   * 是谁关的 —— 没有它，一次断连在 Mac 侧只留下「什么都没记」。
   */
  readonly killed: boolean
}

/**
 * 起一段连接的心跳。
 *
 * 规则三句话：**写还在排队时不判活；对端送来任何一帧都算它还活着；排空之后连失到上限即判死。**
 *
 * 第一条是踩出来的（2026-10-14 真机）：1.25 MB 的打开帧在慢链路上要 ~10 秒才传完，
 * 而我们自己的 ping 与那一大帧走同一条 TCP、排在它**后面** —— 客户端此刻根本收不到
 * ping，收不到就不会回 pong。把这段的「没回」算成死亡证据，等于把「正在传大帧」判成
 * 「客户端死了」，于是连接在帧传到一半时被自己掐断。参考服务端有这个同样的问题，只是
 * 它的链路快到撞不上（`stream-server.ts` 的服务端预算照抄，判据不能照抄）。
 *
 * 第二条是同一次现场的另半边：`writableLength` 只说明**用户态**队列排空了，内核与中继里的
 * 字节还在路上 —— 那时我们刚发出 ping，客户端却还没收到，它自然回不了 pong。**只有 pong 算数
 * 就等于要求「对端在被我们的大帧堵住的间隙里还能应答」**。客户端每 2 秒的 ping 走的是反向、
 * 未被堵住的那条路：收到它，就说明对面活着（与客户端侧同一条规则，见
 * `FollowClient.livenessTick`）。
 *
 * 代价：写不出去的连接不再由心跳判死，交给 TCP 自己的超时；客户端那侧的心跳会在它
 * 自己发现链路死掉时关掉这条连接（两端都留着各自的判据）。
 */
export function startHeartbeat(socket: HeartbeatSocket, options: StreamOptions['heartbeat'] = {}): Heartbeat {
  const intervalMs = options?.intervalMs ?? PING_INTERVAL_MS
  const limit = options?.missedPongLimit ?? MISSED_PONG_LIMIT
  let unanswered = 0
  let killed = false
  const timer = setInterval(() => {
    if (socket.destroyed) return
    if (socket.writableLength > 0) {
      // 见函数注释：这一拍说明不了对面死活，且发出去的 ping 也会排在队尾 ——
      // 既不计数也不发。
      unanswered = 0
      return
    }
    unanswered += 1
    if (unanswered > limit) {
      // 留痕：客户端死亡是常态，但「死于我们自己关掉它」与「客户端自己走了」
      // 是两件事 —— 没有这一行，Mac 侧的日志答不出这次连接怎么结束的
      // （客户端那半边见 `FollowClient` 心跳放弃时的 warn）。
      log.info(`heartbeat: no pong in ${limit + 1} rounds — closing socket`)
      killed = true
      socket.destroy()
      return
    }
    socket.write(encodePing())
  }, intervalMs)
  return {
    heardFrame() { unanswered = 0 },
    stop() { clearInterval(timer) },
    get killed() { return killed },
  }
}

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
  /**
   * 心跳的节拍与容错轮数。**做成可传参不是为了灵活性，是为了让「写还在排队时判不判活」
   * 这条路径能被快速观测**（节拍调到 10ms 就能在测试里看见它）—— 与 `openingCapBytes`
   * 同一条理由。缺省即 {@link PING_INTERVAL_MS} / {@link MISSED_PONG_LIMIT}。
   */
  heartbeat?: { intervalMs?: number; missedPongLimit?: number }
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
  const openedAt = Date.now()
  const parser = new WsFrameParser()
  // 非正的上界会让每次打开都被判成「装不下」—— 归一化规则与 HTTP 路径共享
  // 同一实现（`positiveOrDefault`），不在这里重写一遍。
  const openingCapBytes = positiveOrDefault(options.openingCapBytes, DEFAULT_OPENING_BYTES)
  const streams = new Map<number, { abort: AbortController }>()
  /** 对端是否发过 WebSocket close 帧 —— 收尾日志靠它把「人家自己走的」与「链路掉的」分开。 */
  let peerClosedCleanly = false

  // 心跳规则在 `startHeartbeat`（含「写还在排队时不判活」那条，来由见那里）。
  const heartbeat = startHeartbeat(socket, options.heartbeat)

  const closeAll = (): void => {
    heartbeat.stop()
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
      // 对端送来的任何一帧都是「它还活着」的证据 —— 与客户端侧同一条规则
      //（`FollowClient.livenessTick`）。最要紧的那一帧是客户端每 2 秒一次的 ping：它走的是
      // **未被堵住**的方向（客户端 → 网关），而我们的 pong 可能正排在一大帧后面
      //（真机：1.25 MB 的打开帧 + 中继链路）。此刻收不到它的 pong 说明不了什么。
      heartbeat.heardFrame()
      switch (frame.kind) {
        case 'ping':
          write(socket, encodePong(frame.payload))
          break
        case 'close':
          // 对端**明确**说了再见（WebSocket close 帧）。这是「对端主动关」与「链路直接断」
          // 之间唯一可靠的分界 —— 两者在网关侧都表现为一次 socket close，只有这一帧能区分
          // （真机 2026-10-15：`the peer went away` 分不出「用户切了会话」还是「链路掉了」）。
          peerClosedCleanly = true
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
  // 连接收尾必须留痕：此前这里是 `on('close', closeAll)`，只做清理、一行不记 —— 于是
  // 「谁关的、活了多久、有没有 error」全无据可查（真机 2026-10-15 的「每 35–60 秒断一次」
  // 就卡在这里：客户端有日志，而 Mac 侧沉默）。与 `upgrade accepted → 101` 同属进出边界。
  let finished = false
  let errored = false
  const finish = () => {
    if (finished) return
    finished = true
    const facts = { killed: heartbeat.killed, cleanClose: peerClosedCleanly, errored }
    log.info(`stream ended — ${endReasonOf(facts)}, after ${Math.round((Date.now() - openedAt) / 1000)}s`)
    closeAll()
  }
  socket.on('close', finish)
  socket.on('error', (error) => {
    errored = true
    log.warn(`stream error: ${describeError(error)}`)
    finish()
  })
}

/**
 * 一次连接是怎么结束的 —— 四档，且**可判定**。四者在网关侧都只表现为「socket 关了」，
 * 但后续动作完全不同：**我们掐的**要改心跳规则；**对端主动关的**是正常（用户切了会话、
 * 关了 App）；**链路掉的**要查传输/系统；**报错的**直接读错误原文。
 *
 * 判据取真实收到的信号，不靠推断：`error` 事件 > 自己心跳留下的标记 > 对端发来的
 * WebSocket close 帧。三者都没有 = 断在半路（FIN 都没来得及）。
 */
export function endReasonOf(facts: { killed: boolean; cleanClose: boolean; errored: boolean }): string {
  if (facts.errored) return 'the socket errored'
  if (facts.killed) return 'we closed it (no pong)'
  if (facts.cleanClose) return 'the peer closed it cleanly'
  return 'the link dropped'
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
  const readModel = (): ModelSelection | undefined => {
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
      // R8 期2：取亚毫秒（perfNow），t2 的分辨力不再止于 1 ms。
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
        // 占用基线与窗口同一口气读出：手机打开时拿到的是同一时刻的
        // 窗口与状态。
        const occupancy = readUsage()
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
          }, perfNow(), frameBytesAt(0)))
          send(socket, {
            type: 'error',
            streamId,
            payload: { code: 'window-too-large', message: 'the most recent turn alone exceeds this connection\'s opening size cap' },
          })
          return
        }

        const sentCount = events.length - shrink.start
        // 字节数进 info 行（不是只在 debug 的 perf 记录里）：慢链路上「帧有多大」与
        // 「传了多久」是两件事，而这一行是「传了多久」的一半已知量 ——
        // 另一半在客户端。**并把两半分开报**：收窄只裁得动 `events`，未定稿基线 /
        // 占用 / 模型基线都裁不动，却同样占着上界的额度（真机：某会话事件 1.2 MiB、
        // 帧却 >4 MiB —— 多出来的 2.8 MiB 全在裁不动的那一半里）。
        const openingBytes = frameBytesAt(shrink.start)
        const fixedBytes = encodeTextFrame(encodeServerFrame({
          type: 'item', streamId, payload: { ...openingPayload(shrink.start), events: [] },
        })).length
        log.info(`follow opening for "${request.sessionId}": cursor=${cursor}, ${sentCount} events`
          + (shrink.cutEvents === 0 ? '' : ` (narrowed by ${shrink.cutEvents} events / ${shrink.cutTurns} turns)`)
          + `, ${openingBytes} bytes (fixed ${fixedBytes} + events ${openingBytes - fixedBytes})`)
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
    const gwSend = perfNow()
    perfRecord(LogModule.ws, gwRecord(perf, gwSend, frameBytes.length))
  }
  write(socket, frameBytes)
}

function write(socket: Duplex, buffer: Buffer): void {
  if (socket.destroyed) return
  socket.write(buffer)
}
