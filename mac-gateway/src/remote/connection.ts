/**
 * 一条连接：握手、成帧循环、心跳、以及与对端怎么结束的判定。
 *
 * 存活范围是**一条 socket**。握手拒绝、成帧破坏、心跳超时、对端关闭 —— 这四件事
 * 都只带走这一条连接：字节破坏时 `socket.destroy()`，心跳掐自己这一条，收尾只清
 * 自己名下的流。集合与其它连接不受影响。
 *
 * 一条流的失败也不该带走这里：泵在 `stream.ts` 里自己收容（catch 成 error 帧）。
 */

import type { Duplex } from 'node:stream'
import type { IncomingMessage } from 'node:http'
import type { StreamId } from '../wire/mux.ts'
import type { ApprovalSource } from '../ports/approval.ts'
import { DEFAULT_LIMITS, positiveOrDefault } from '../protocol/rpc.ts'
import { describeError } from '../ports/errors.ts'
import type { FollowSource } from '../ports/follow.ts'
import type { ForwardedSource } from '../ports/events.ts'
import {
  WsFrameParser,
  acceptKeyOf,
  encodeClose,
  encodePing,
  encodePong,
  handshakeResponse,
} from './frames.ts'
import { onClientText } from './stream.ts'
import { send, write } from './egress.ts'
import { createLogger, LogModule, perfRecord } from '../log.ts'

const log = createLogger(LogModule.ws)

/** 本网关提供流协议的精确路径。 */
export const STREAM_PATH = '/rpc/stream'

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
 * 第一条的理由：一个几 MB 的打开帧在慢链路上要传好几秒，而我们自己的 ping 与那一大帧
 * 走同一条 TCP、排在它**后面** —— 客户端此刻根本收不到 ping，收不到就不会回 pong。
 * 把这段的「没回」算成死亡证据，等于把「正在传大帧」判成「客户端死了」，于是连接在
 * 帧传到一半时被自己掐断。
 *
 * 第二条是同一件事的另半边：`writableLength` 只说明**用户态**队列排空了，内核与中继里的
 * 字节还在路上 —— 那时我们刚发出 ping，客户端却还没收到，它自然回不了 pong。**只有 pong 算数
 * 就等于要求「对端在被我们的大帧堵住的间隙里还能应答」**。客户端每 2 秒的 ping 走的是反向、
 * 未被堵住的那条路：收到它，就说明对面活着（与客户端侧同一条规则，见
 * `StreamTransport.livenessTick`）。
 *
 * 代价：写不出去的连接不再由心跳判死，交给 TCP 自己的超时；客户端那侧的心跳会在它
 * 自己发现链路死掉时关掉这条连接（两端都留着各自的判据）。
 */
export function startHeartbeat(socket: HeartbeatSocket, options: StreamOptions['heartbeat'] = {}): Heartbeat {
  const intervalMs = options.intervalMs ?? PING_INTERVAL_MS
  const limit = options.missedPongLimit ?? MISSED_PONG_LIMIT
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
      // （客户端那半边见 `StreamTransport` 心跳放弃时的 warn）。
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
 * 打开帧的默认字节上界 —— 与 HTTP 路径的上限同处一族，定义在
 * `protocol/rpc.ts` 的 `DEFAULT_LIMITS`（那里有取值来由）。做成可传参而非常量，
 * 理由与 `maxDeltaEvents` 相同：让收窄路径**可被端到端观测**（调到极小值就能
 * 看见它发生），而不是只活在文档里。
 */
export const DEFAULT_OPENING_BYTES = DEFAULT_LIMITS.maxOpeningBytes

/** 流适配器的可调项。 */
export interface StreamOptions {
  /**
   * 进程里那份转发事件源（`{op:'events'}` 的流订阅它）。
   *
   * 缺席**不是**降级路径：装配忘了接它时，事件流要拿到一条显式的拒绝，而不是一条
   * 永远等不到正文的流。只在「这台网关不提供事件流」的测试里才该缺席。
   */
  events?: ForwardedSource
  /**
   * 审批的当前集合与变化 —— 与 `events` 成对出现：事件流是它唯一的投递通道。
   *
   * 与 `events` 分开声明是因为它们回答两件事：`events` 说"有没有源"，它说"待答项
   * 现在是什么"。缺了它，`{op:'events'}` 同样要被拒绝（装配错误）。
   */
  approvals?: ApprovalSource
  /** 打开帧的字节上界；缺省即 {@link DEFAULT_OPENING_BYTES}。 */
  openingCapBytes?: number
  /**
   * 心跳的节拍与容错轮数。**做成可传参不是为了灵活性，是为了让「写还在排队时判不判活」
   * 这条路径能被快速观测**（节拍调到 10ms 就能在测试里看见它）—— 与 `openingCapBytes`
   * 同一条理由。缺省即 {@link PING_INTERVAL_MS} / {@link MISSED_PONG_LIMIT}。
   */
  heartbeat?: { intervalMs?: number; missedPongLimit?: number }
}

export async function handleUpgrade(
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
}

/** 每连接的状态与循环。 */
function runSocket(socket: Duplex, source: FollowSource, head: Buffer, options: StreamOptions): void {
  const openedAt = Date.now()
  const parser = new WsFrameParser()
  // 非正的上界会让每次打开都被判成「装不下」—— 归一化规则与 HTTP 路径共享
  // 同一实现（`positiveOrDefault`），不在这里重写一遍。
  const openingCapBytes = positiveOrDefault(options.openingCapBytes, DEFAULT_OPENING_BYTES)
  const streams = new Map<StreamId, { abort: AbortController }>()
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
      //（`StreamTransport.livenessTick`）。最要紧的那一帧是客户端每 2 秒一次的 ping：它走的是
      // **未被堵住**的方向（客户端 → 网关），而我们的 pong 可能正排在一个大帧后面。
      // 此刻收不到它的 pong 说明不了什么。
      heartbeat.heardFrame()
      switch (frame.kind) {
        case 'ping':
          write(socket, encodePong(frame.payload))
          break
        case 'close':
          // 对端**明确**说了再见（WebSocket close 帧）。这是「对端主动关」与「链路直接断」
          // 之间唯一可靠的分界 —— 两者在网关侧都表现为一次 socket close，只有这一帧能区分。
          // 少了它，「the link dropped」这句话就分不出「手机正常关了 App」与「链路掉了」。
          peerClosedCleanly = true
          write(socket, encodeClose())
          socket.end()
          break
        case 'text': {
          const outcome = onClientText(socket, source, options.events, options.approvals, streams, frame.text, openingCapBytes)
          if (outcome.ok) break
          // 两档都在这里关连接，但原因不同，日志必须分得开：
          //   重复编号 —— 客户端坏了，这条连接上的一切都不再可信；
          //   归不到流 —— 帧读不出编号，没有可拒收它的流（有编号的坏载荷不走这条路）。
          // 静默忽略的表现是「客户端等 45 秒就绪超时」，两端都看不出原因。
          log.error(outcome.reason === 'duplicate-id'
            ? 'stream protocol violation: duplicate stream id — closing the connection'
            : `stream protocol violation: frame belongs to no stream (${outcome.excerpt}) — closing the connection`)
          socket.destroy()
          return
        }
      }
    }
  }

  // 帧可能搭在升级请求的最后字节里。
  if (head.length > 0) onChunk(head)
  socket.on('data', onChunk)
  // 连接收尾必须留痕：只做清理、不记一行的话，「谁关的、活了多久、有没有 error」三件事
  // 就全无据可查 —— 客户端那边有日志，而 Mac 侧沉默，一次反复断连会卡在这里。
  // 它与 `upgrade accepted → 101` 同属进出边界。
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
 * 但后续动作完全不同：**我们掐的**要改心跳规则；**对端主动关的**是正常（关了 App、
 * 手机释放了连接）；**链路掉的**要查传输/系统；**报错的**直接读错误原文。
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
