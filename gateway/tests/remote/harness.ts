/**
 * 传输层测试的共用夹具：真 WebSocket 客户端对真监听器，源是假的。
 *
 * 三个故障域（集合 / 一条连接 / 一条流）共用这套夹具，所以它们不装自己的那份 ——
 * 抄三份的下场是「改一处漏两处」，而这个文件的每一行都会被三边同时用到。
 *
 * 客户端用 Node 自带的 `WebSocket`：它就是 iOS 客户端说的那个 RFC 6455，
 * 因此这里验的是真协议，不是我们自己的假件。
 */

import assert from 'node:assert/strict'
import type { Server } from 'node:http'
import { STREAM_PATH } from '../../src/remote/connection.ts'
import type { FollowSource, UpstreamFollowFrame } from '../../src/ports/follow.ts'
import type { ProjectionBaseline } from '../../src/wire/rpc.ts'
import type { ForwardedSink, ForwardedSource, UpstreamWireFrame } from '../../src/ports/events.ts'
import type { WireEvent } from '../../src/wire/rpc.ts'

/**
 * 一份**由测试驱动**的转发事件源：换代次、发帧都在测试手里。
 *
 * 与 `fakeSource` 同一条分工 —— 这里替代的是「上游的 `$events` 身份」（网络与宿主之外），
 * 而流、socket、成帧都是真的。
 */
export function fakeFeed(): ForwardedSource & {
  emit(event: string, args: unknown): void
  push(frame: UpstreamWireFrame): void
  /** 换代次；`undefined` = 源失效。 */
  setGeneration(generation: number | undefined): void
  /** 这一代的宿主工作目录。 */
  setHost(host: { home: string } | undefined): void
  subscribers(): number
} {
  const sinks = new Set<ForwardedSink>()
  let current: number | undefined
  let host: { home: string } | undefined
  return {
    get generation() { return current },
    host: () => host,
    subscribe(sink) {
      sinks.add(sink)
      return () => { sinks.delete(sink) }
    },
    setGeneration(generation) {
      current = generation
      for (const sink of sinks) sink.generation(generation)
    },
    setHost(next) {
      host = next
    },
    emit(event, args: readonly unknown[]) {
      for (const sink of sinks) sink.frame({ type: 'emit', event, args })
    },
    push(frame) {
      for (const sink of sinks) sink.frame(frame)
    },
    subscribers: () => sinks.size,
  }
}

/** A follow source replaying scripted frames, optionally lying. */
export function fakeSource(
  frames: UpstreamFollowFrame[],
  options: { failWith?: unknown } = {},
): FollowSource & { calls: number; requests: unknown[] } {
  return {
    calls: 0,
    requests: [],
    // 这套夹具只造事件流：`controlBaseline` 是可选面，整套夹具不造投影 —— 一个值都不伪造。
    async *follow(request, signal) {
      this.calls += 1
      this.requests.push(request)
      if (request.address.kind !== 'session') throw new Error('test only supports session follows')
      if (options.failWith !== undefined) throw options.failWith
      for (const frame of frames) {
        if (signal.aborted) return
        yield frame
      }
    },
  }
}

/**
 * 打开一条 follow 流的 `args` —— 上游 `SessionFollowRequest` 那几格，外面套一层宿主
 * 形参同名的 `request` 容器。
 *
 * 每个键都写全（不是随手给个 `address`）：网关「不补默认值」这件事只有在请求本身
 * 带全时才看得出来 —— 少给一格，夹具就替网关把默认值补上了。
 */
export function openArgs(sessionId: string): unknown {
  return {
    request: {
      address: { kind: 'session', sessionId },
      activate: true,
      assistantStream: true,
      maxMessages: 500,
      turnWindow: { minMessages: 50, minTurns: 2 },
    },
  }
}

/** Connect a real WebSocket client to `server`, post-upgrade. */
export async function connect(server: Server): Promise<WebSocket> {
  const address = server.address()
  assert.ok(address !== null && typeof address === 'object')
  const socket = new WebSocket(`ws://127.0.0.1:${address.port}${STREAM_PATH}`)
  await socketEvent(socket, 'open')
  return socket
}

/**
 * One event from the client socket. Node's built-in WebSocket is an EventTarget, not
 * an EventEmitter — `events.once` never sees its events, which is a hang, not an error.
 */
function socketEvent(socket: WebSocket, type: string): Promise<{ data?: unknown; code?: unknown }> {
  return new Promise((resolve, reject) => {
    socket.addEventListener(type, event => {
      resolve(event as { data?: unknown; code?: unknown })
    }, { once: true })
    socket.addEventListener('error', () => { reject(new Error(`socket ${type} before event "${type}"`)) }, { once: true })
  })
}

/** Receive one mux text frame as a parsed object — queued, see {@link receiverFor}. */
export async function receive(socket: WebSocket): Promise<Record<string, unknown>> {
  return receiverFor(socket).receive()
}

/** The per-socket frame receiver: one continuous listener, a queue, receive-with-timeout.
 *
 * The pump writes frames back-to-back, so several `message` events can fire between two
 * `receive` calls — a listen-only-when-asked helper would miss them and hang. Hence the
 * queue (order-sensitive, not timing-sensitive) and one listener per socket.
 */
const receivers = new WeakMap<WebSocket, { receive: (timeoutMs?: number) => Promise<Record<string, unknown>> }>()

function receiverFor(socket: WebSocket): { receive: (timeoutMs?: number) => Promise<Record<string, unknown>> } {
  const existing = receivers.get(socket)
  if (existing !== undefined) return existing

  const queue: Record<string, unknown>[] = []
  const waiters: ((frame: Record<string, unknown>) => void)[] = []
  socket.addEventListener('message', event => {
    const parsed = JSON.parse(String((event as { data: unknown }).data)) as Record<string, unknown>
    const waiter = waiters.shift()
    if (waiter !== undefined) waiter(parsed)
    else queue.push(parsed)
  })
  socket.addEventListener('error', () => {
    for (const waiter of waiters.splice(0)) waiter({ type: '__socket_error__' })
  })

  const receiver = {
    receive(timeoutMs = 5_000): Promise<Record<string, unknown>> {
      const queued = queue.shift()
      if (queued !== undefined) return Promise.resolve(queued)
      return new Promise((resolve, reject) => {
        waiters.push(resolve)
        setTimeout(() => { reject(new Error('receive timed out — no frame arrived')) }, timeoutMs)
      })
    },
  }
  receivers.set(socket, receiver)
  return receiver
}

export function send(socket: WebSocket, payload: unknown): void {
  socket.send(JSON.stringify(payload))
}

/** An event the wire promises: `{type, seq, time, data}` verbatim. */
export function event(seq: number): WireEvent {
  return { type: seq % 2 === 0 ? 'user/message' : 'assistant/message', seq, time: 1_700_000_000_000 + seq, data: { text: `m${seq}` } }
}

/**
 * 上游 `snapshot` 的一帧 —— 与宿主同形：`header`/`cursor`/`records`/`hasMore`/`projections`
 * 都在，`assistantStream` 可选。
 *
 * `header` 与 `projections` 是**必填**的：宿主类型里就是必填，夹具若给缺一格的帧，
 * 「客户端缺字段就丢帧」那条规则在网关侧就永远测不到（网关只会转发它）。
 */
export function snapshotFrame(
  log: readonly WireEvent[],
  windowSize: number,
  extra: { projections?: ProjectionBaseline; assistantStream?: unknown } = {},
): UpstreamFollowFrame {
  const records = log.slice(-windowSize).map(ev => ({ type: 'event' as const, event: ev }))
  return {
    type: 'snapshot',
    header: { version: 1, id: 's-1', createdAt: 1_700_000_000_000, cwd: '/tmp/x', isSeeded: false },
    cursor: log.length - 1,
    records,
    hasMore: log.length > windowSize,
    projections: extra.projections ?? { asOfSeq: log.length - 1, values: {} },
    ...(extra.assistantStream === undefined ? {} : { assistantStream: extra.assistantStream }),
  }
}

/** A turn boundary — the only place an opening window may be cut on. */
export function turn(seq: number): WireEvent {
  return { type: 'turn/start', seq, time: 1_700_000_000_000 + seq, data: {} }
}

/** An event padded to roughly `bytes` of wire text, to make a window overflow a cap. */
export function filler(seq: number, bytes: number): WireEvent {
  return { type: 'user/message', seq, time: 1_700_000_000_000 + seq, data: { text: 'x'.repeat(bytes) } }
}
