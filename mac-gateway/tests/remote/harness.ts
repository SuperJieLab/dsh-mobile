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
import type { FollowSource, ProjectionBaseline, UpstreamFollowFrame } from '../../src/ports/follow.ts'
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
  subscribers(): number
} {
  const sinks = new Set<ForwardedSink>()
  let current: number | undefined
  return {
    get generation() { return current },
    subscribe(sink) {
      sinks.add(sink)
      return () => { sinks.delete(sink) }
    },
    setGeneration(generation) {
      current = generation
      for (const sink of sinks) sink.generation(generation)
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
    // 这套夹具只造事件流：`occupancyOf` 是必填形状，这里给「不知道」；`modelOf` 是可选的，
    // 整套夹具不造模型基线 —— 一个值都不伪造。
    occupancyOf: () => undefined,
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

export function snapshotFrame(
  log: readonly WireEvent[],
  windowSize: number,
  extra: { projections?: ProjectionBaseline } = {},
): UpstreamFollowFrame {
  const records = log.slice(-windowSize).map(ev => ({ type: 'event' as const, event: ev }))
  return {
    type: 'snapshot',
    cursor: log.length - 1,
    records,
    hasMore: log.length > windowSize,
    ...extra,
  }
}

/** A turn boundary — the only place an opening window may be cut on (R9 期1). */
export function turn(seq: number): WireEvent {
  return { type: 'turn/start', seq, time: 1_700_000_000_000 + seq, data: {} }
}

/** An event padded to roughly `bytes` of wire text, to make a window overflow a cap. */
export function filler(seq: number, bytes: number): WireEvent {
  return { type: 'user/message', seq, time: 1_700_000_000_000 + seq, data: { text: 'x'.repeat(bytes) } }
}
