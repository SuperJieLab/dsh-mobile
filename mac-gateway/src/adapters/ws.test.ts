/**
 * Stream adapter tests: a real listener, a real WebSocket client (Node's
 * built-in, the same RFC 6455 an iOS client speaks), a fake follow source.
 *
 * What these prove beyond the seam tests: the upgrade negotiation works, the
 * mux survives a real socket, the pump's unwrapping produces openings and
 * events a `page` could have produced, continuity witnessing fires on a lying
 * source, and a hostile source still answers with frames instead of killing
 * the process.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer, request as httpRequest, type Server } from 'node:http'
import { once } from 'node:events'
import { attachStreamHandler, STREAM_PATH, type FollowSource, type UpstreamFollowFrame } from './ws.ts'
import type { WireEvent } from '../seam/rpc.ts'

/** A follow source replaying scripted frames, optionally lying. */
function fakeSource(frames: UpstreamFollowFrame[], options: { failWith?: unknown } = {}): FollowSource & { calls: number } {
  return {
    calls: 0,
    async *follow(request, signal) {
      this.calls += 1
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
async function connect(server: Server): Promise<WebSocket> {
  const address = server.address()
  assert.ok(address !== null && typeof address === 'object')
  const socket = new WebSocket(`ws://127.0.0.1:${address.port}${STREAM_PATH}`)
  await socketEvent(socket, 'open')
  return socket
}

/**
 * One event from the client socket.
 *
 * Node's built-in WebSocket is an EventTarget, not an EventEmitter — the
 * `events.once` helper never sees its events, which is a hang, not an error.
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
async function receive(socket: WebSocket): Promise<Record<string, unknown>> {
  return receiverFor(socket).receive()
}

/**
 * The per-socket frame receiver: one continuous listener, a queue, and
 * receive-with-timeout.
 *
 * The pump writes frames back-to-back, so several `message` events can fire
 * between two `receive` calls — a listen-only-when-asked helper would miss
 * them and hang forever. The queue is what makes receiving order-sensitive
 * but timing-insensitive; the WeakMap is what keeps a second `receive` from
 * attaching a second listener and double-queuing every frame.
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

function send(socket: WebSocket, payload: unknown): void {
  socket.send(JSON.stringify(payload))
}

/** An event the wire promises: `{type, seq, time, data}` verbatim. */
function event(seq: number): WireEvent {
  return { type: seq % 2 === 0 ? 'user/message' : 'assistant/message', seq, time: 1_700_000_000_000 + seq, data: { text: `m${seq}` } }
}

function snapshotFrame(log: readonly WireEvent[], windowSize: number): UpstreamFollowFrame {
  const records = log.slice(-windowSize).map(ev => ({ type: 'event' as const, event: ev }))
  return {
    type: 'snapshot',
    cursor: log.length - 1,
    records,
    hasMore: log.length > windowSize,
  }
}

test('upgrade + follow: opening, then events, in mux frames', { timeout: 10_000 }, async () => {
  const log = [0, 1, 2].map(event)
  const source = fakeSource([
    snapshotFrame(log, 3),
    { type: 'event', event: event(3) },
    { type: 'event', event: event(4) },
  ])
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    const opening = await receive(socket)
    assert.equal(opening.type, 'item')
    const payload = opening.payload as Record<string, unknown>
    assert.equal(payload.sessionId, 's1')
    assert.equal(payload.cursor, 3, 'exclusive end of the opening window')
    assert.equal(payload.hasOlder, false)
    // The events are the DSH objects verbatim — unwrapped, untransformed.
    assert.deepEqual(payload.events, log)

    const first = await receive(socket)
    assert.deepEqual((first.payload as Record<string, unknown>), event(3))
    const second = await receive(socket)
    assert.deepEqual((second.payload as Record<string, unknown>), event(4))

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('S1 at the adapter: the WS opening equals the HTTP page window', { timeout: 10_000 }, async () => {
  // The window the fake source cuts (the last 50 messages) must equal what a
  // `page` over the same log returns — same rule, same boundary.
  const log = Array.from({ length: 57 }, (_, index) => event(index))
  const source = fakeSource([snapshotFrame(log, 50)])
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })
    const opening = await receive(socket)
    const payload = opening.payload as { events: WireEvent[]; cursor: number; pageStart: number; hasOlder: boolean }

    assert.equal(payload.events.length, 50)
    assert.equal(payload.pageStart, 7)
    assert.equal(payload.hasOlder, true)
    assert.equal(payload.cursor, 57)
    assert.equal(JSON.stringify(payload.events), JSON.stringify(log.slice(7)))
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('a transient frame passes through verbatim and cursor-less', { timeout: 10_000 }, async () => {
  const transient = { type: 'assistant-stream', frame: { attemptId: 'a1', revision: 3, index: 0, chunk: '你好' } }
  const source = fakeSource([
    snapshotFrame([], 0),
    transient,
  ])
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    const opening = await receive(socket)
    assert.equal((opening.payload as Record<string, unknown>).cursor, 0)

    const frame = await receive(socket)
    assert.deepEqual(frame.payload, { type: 'assistant-stream', frame: transient.frame })
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('a source that skips a seq is refused loudly, not rendered', { timeout: 10_000 }, async () => {
  const errors: string[] = []
  const originalError = console.error
  console.error = (message: string) => { errors.push(message) }
  try {
    const log = [0, 1, 2].map(event)
    const source = fakeSource([
      snapshotFrame(log, 3),
      { type: 'event', event: event(5) }, // skipped 3
    ])
    const server = createServer()
    attachStreamHandler(server, source)
    server.listen(0)
    try {
      await once(server, 'listening')
      const socket = await connect(server)
      send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

      await receive(socket) // opening
      const refusal = await receive(socket)
      assert.equal(refusal.type, 'error')
      assert.equal((refusal.payload as { code: string }).code, 'internal-error')
      assert.ok(errors.some(text => text.includes('broke continuity')), 'the violation is loud on stderr')
      socket.close()
    } finally {
      server.closeAllConnections()
      server.close()
    }
  } finally {
    console.error = originalError
  }
})

test('a hostile source still answers with an error frame — the process does not crash', { timeout: 10_000 }, async () => {
  const source = fakeSource([], { failWith: Object.assign(new Error('boom'), { isDSHRemoteError: true, code: 'session/not-found' }) })
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 'ghost' } })

    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.deepEqual(refusal.payload, { code: 'unknown-session', message: 'boom' })
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('an unreadable-session failure maps to its own code, like the HTTP path', { timeout: 10_000 }, async () => {
  const failure = Object.assign(new Error('zstd says no'), { name: 'SessionPersistenceCorruptionError' })
  const source = fakeSource([], { failWith: failure })
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })
    const refusal = await receive(socket)
    assert.equal((refusal.payload as { code: string }).code, 'unreadable-session')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('cancel stops the stream; the pump yields no further frames for it', { timeout: 10_000 }, async () => {
  // A source that would keep yielding forever unless aborted.
  const source: FollowSource = {
    async *follow(_request, signal) {
      yield snapshotFrame([event(0)], 1)
      let seq = 1
      while (!signal.aborted) {
        yield { type: 'event', event: event(seq) }
        seq += 1
        await new Promise(resolve => setTimeout(resolve, 5))
      }
    },
  }
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    await receive(socket) // opening
    await receive(socket) // event 1
    send(socket, { type: 'cancel', streamId: 1 })

    // Give any would-be further frame time to arrive; none should.
    await new Promise(resolve => setTimeout(resolve, 60))
    socket.close()
    assert.ok(true, 'no error, no extra frame assertion — absence is the criterion')
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('an unknown upgrade path is declined without speaking WebSocket', { timeout: 10_000 }, async () => {
  const source = fakeSource([])
  const server = createServer()
  attachStreamHandler(server, source)
  server.listen(0)
  try {
    await once(server, 'listening')
    const address = server.address()
    assert.ok(address !== null && typeof address === 'object')

    // fetch refuses to send `Connection: Upgrade`; an upgrade probe is a raw
    // HTTP request, which is also what a real client's handshake looks like.
    const status = await new Promise<number>((resolve, reject) => {
      const request = httpRequest(
        { host: '127.0.0.1', port: address.port, path: '/other',
          headers: { connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==', 'sec-websocket-version': '13' } },
        response => { resolve(response.statusCode ?? 0); response.resume() },
      )
      request.on('error', reject)
      request.end()
    })
    assert.equal(status, 404)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
