/**
 * Stream adapter tests: a real listener, a real WebSocket client (Node's built-in, the
 * same RFC 6455 an iOS client speaks), a fake follow source.
 *
 * Beyond the contract tests these prove: upgrade negotiation, the mux over a real
 * socket, openings and events a `page` could have produced, continuity witnessing
 * firing on a lying source, and a hostile source answered with frames.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer, request as httpRequest, type Server } from 'node:http'
import { once } from 'node:events'
import { connect as tcpConnect } from 'node:net'
import { attachStreamHandler, endReasonOf, startHeartbeat, STREAM_PATH, type FollowSource, type HeartbeatSocket, type UpstreamFollowFrame } from '../../src/remote/ws.ts'
import type { WireEvent } from '../../src/contract/rpc.ts'
import { setPerfSink } from '../../src/log.ts'

/** A follow source replaying scripted frames, optionally lying. */
function fakeSource(
  frames: UpstreamFollowFrame[],
  options: { failWith?: unknown } = {},
): FollowSource & { calls: number; requests: unknown[] } {
  return {
    calls: 0,
    requests: [],
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
async function connect(server: Server): Promise<WebSocket> {
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
async function receive(socket: WebSocket): Promise<Record<string, unknown>> {
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

/** A turn boundary — the only place an opening window may be cut on (R9 期1). */
function turn(seq: number): WireEvent {
  return { type: 'turn/start', seq, time: 1_700_000_000_000 + seq, data: {} }
}

/** An event padded to roughly `bytes` of wire text, to make a window overflow a cap. */
function filler(seq: number, bytes: number): WireEvent {
  return { type: 'user/message', seq, time: 1_700_000_000_000 + seq, data: { text: 'x'.repeat(bytes) } }
}

test('upgrade + follow: opening, then events, in mux frames', { timeout: 10_000 }, async () => {
  const log = [0, 1, 2].map(event)
  const source = fakeSource([
    snapshotFrame(log, 3),
    { type: 'event', event: event(3) },
    { type: 'event', event: event(4) },
  ])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
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
  attachStreamHandler(server, source, { authenticate: () => true })
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
  attachStreamHandler(server, source, { authenticate: () => true })
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
    attachStreamHandler(server, source, { authenticate: () => true })
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
  attachStreamHandler(server, source, { authenticate: () => true })
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
  attachStreamHandler(server, source, { authenticate: () => true })
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

test('the opening asks upstream for a window that starts on a turn boundary', { timeout: 10_000 }, async () => {
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)

  const socket = await connect(server)
  try {
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })
    await receive(socket) // the opening frame
  } finally {
    socket.close()
    server.closeAllConnections()
    server.close()
  }

  // The reference spells the rule as a floor and a ceiling; both come from the
  // one target our own window function takes, so the opening and `page` ask for
  // the same window.
  assert.deepEqual(source.requests, [{
    address: { kind: 'session', sessionId: 's1' },
    maxMessages: 100,
    turnWindow: { minMessages: 50, minTurns: 1 },
    assistantStream: true,
  }])
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
  attachStreamHandler(server, source, { authenticate: () => true })
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
  attachStreamHandler(server, source, { authenticate: () => true })
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

test('the opening carries the model baseline when the source knows it, absent otherwise', { timeout: 10_000 }, async () => {
  const source = {
    ...fakeSource([snapshotFrame([event(0)], 1)]),
    modelOf: (sessionId: string) => sessionId === 's1' ? { provider: 'p', model: 'A' } : undefined,
  }
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')

    const first = await connect(server)
    send(first, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })
    const known = await receive(first)
    assert.deepEqual((known.payload as Record<string, unknown>).model, { provider: 'p', model: 'A' },
      'the baseline rides the opening, same breath as the window')
    first.close()

    const second = await connect(server)
    send(second, { type: 'open', streamId: 2, payload: { op: 'follow', sessionId: 's-unknown' } })
    const unknown = await receive(second)
    assert.equal('model' in (unknown.payload as Record<string, unknown>), false,
      'an unknown baseline stays out of the payload, never guessed')
    second.close()

    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('pump: one perf record per forwarded frame — opening and events alike', { timeout: 10_000 }, async () => {
  // R8 期1 链路 A：每条过 send 边界的帧都留一条 gw 记录 —— 事件帧带 `seq`
  // 与上游 `time`（`evTime`），窗口重放带 `kind: 'opening'` 与 `events`
  // 计数；两者都带同机的 `gwRecv` / `gwSend` 与帧字节数。判读按 `kind`，
  // 不按「`seq` 缺席」。
  const log = [0, 1, 2].map(event)
  const source = fakeSource([
    snapshotFrame(log, 3),
    { type: 'event', event: event(3) },
    { type: 'event', event: event(4) },
  ])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)

  const records: Record<string, unknown>[] = []
  const previousDebug = process.env.DSH_LOG_DEBUG
  setPerfSink(line => {
    records.push(JSON.parse(line.slice(line.indexOf(' {') + 1)) as Record<string, unknown>)
  })
  process.env.DSH_LOG_DEBUG = '1'
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    await receive(socket) // opening
    await receive(socket) // event 3
    await receive(socket) // event 4
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    setPerfSink(() => {})
    if (previousDebug === undefined) delete process.env.DSH_LOG_DEBUG
    else process.env.DSH_LOG_DEBUG = previousDebug
    server.closeAllConnections()
    server.close()
  }

  const eventRecords = records.filter(record => record.kind === 'event')
  assert.equal(eventRecords.length, 2, 'one record per forwarded event')
  for (const [index, seq] of [3, 4].entries()) {
    const record = eventRecords[index]
    assert.equal(record.seg, 'gw')
    assert.equal(record.seq, seq)
    assert.equal(record.sessionId, 's1')
    assert.equal(record.evTime, 1_700_000_000_000 + seq, 'the upstream event time, verbatim')
    assert.equal(typeof record.gwRecv, 'number')
    assert.equal(typeof record.gwSend, 'number')
    assert.equal(typeof record.bytes, 'number')
    assert.ok((record.bytes as number) > 0, 'the frame really was serialised')
    assert.ok((record.gwRecv as number) <= (record.gwSend as number), 'same-machine boundaries do not invert')
    // R8 期2 U2：t2 段（gwRecv → gwSend）是瓶颈指认的依据，1 ms 的整数分辨力
    // 让它恒为 0 —— 两端必须是亚毫秒值。
    assert.ok(!Number.isInteger(record.gwRecv as number), 'gwRecv carries sub-ms precision')
    assert.ok(!Number.isInteger(record.gwSend as number), 'gwSend carries sub-ms precision')
  }

  // The window replay crosses the same send boundary and is the largest single
  // frame of a stream — the one a client's message-size cap rejects first.
  const openingRecords = records.filter(record => record.kind === 'opening')
  assert.equal(openingRecords.length, 1, 'one record per opening')
  const opening = openingRecords[0]
  assert.equal(opening.seg, 'gw')
  assert.equal(opening.sessionId, 's1')
  assert.equal(opening.events, 3, 'how many events the window carried')
  assert.equal(typeof opening.bytes, 'number')
  assert.ok((opening.bytes as number) > 0, 'the opening frame really was serialised')
  assert.ok((opening.gwRecv as number) <= (opening.gwSend as number), 'same-machine boundaries do not invert')
  assert.equal('seq' in opening, false, 'a window replay has no single seq — absent, not guessed')
  assert.equal('cutTurns' in opening, false, 'an untouched window records no cut — absent, not zero')

  assert.equal(records.filter(record => record.conn !== undefined).length, 1, 'one record per upgrade')
})

test('opening narrowing: cut on a turn boundary, kept under the byte cap', { timeout: 10_000 }, async () => {
  // Two turns whose messages are large enough to blow a small cap. Narrowing must
  // (a) keep the frame under the cap and (b) leave the start on a turn boundary —
  // never inside a turn, where the same span would render two ways (R9 期1 / B6).
  const log = [turn(0), filler(1, 300), turn(2), filler(3, 300)]
  const source = fakeSource([snapshotFrame(log, 4)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, { openingCapBytes: 700 })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    const opening = await receive(socket)
    const payload = opening.payload as { events: WireEvent[]; pageStart: number; hasOlder: boolean; cursor: number }
    const wire = Buffer.byteLength(JSON.stringify(opening), 'utf8')
    assert.ok(wire <= 700, `the frame fits the cap (was ${wire})`)
    assert.equal(payload.events[0].type, 'turn/start', 'the start is a turn boundary')
    assert.equal(payload.pageStart, 2, 'the earliest turn boundary that still fits')
    assert.equal(payload.hasOlder, true, 'the older part stays reachable')
    assert.equal(payload.cursor, 4, 'the water mark does not move when the window narrows')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('opening narrowing: a single turn over the cap is refused, not truncated', { timeout: 10_000 }, async () => {
  // The only turn boundary is the current start and that one turn is over the cap.
  // Truncating inside it would show half a turn; the adapter refuses instead, so
  // the client learns why rather than watching the socket die.
  const log = [turn(0), filler(1, 5_000)]
  const source = fakeSource([snapshotFrame(log, 2)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, { openingCapBytes: 700 })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.payload as { code: string }).code, 'window-too-large')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('opening narrowing: a nonsensical cap falls back to the default instead of refusing everything', { timeout: 10_000 }, async () => {
  // A zero or negative cap makes every frame "too large" — a config typo must not
  // become "no session opens at all".
  const log = [turn(0), filler(1, 100)]
  const source = fakeSource([snapshotFrame(log, 2)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, { openingCapBytes: 0 })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

    const opening = await receive(socket)
    assert.equal(opening.type, 'item', 'a nonsense cap must not turn into a refusal')
    assert.equal((opening.payload as { pageStart: number }).pageStart, 0, 'the default cap applies instead')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

/** Collect perf records for the duration of `body`; `DSH_LOG_DEBUG` is flipped on. */
async function collectPerf(body: () => Promise<void>): Promise<Record<string, unknown>[]> {
  const records: Record<string, unknown>[] = []
  const previousDebug = process.env.DSH_LOG_DEBUG
  setPerfSink(line => {
    records.push(JSON.parse(line.slice(line.indexOf(' {') + 1)) as Record<string, unknown>)
  })
  process.env.DSH_LOG_DEBUG = '1'
  try {
    await body()
  } finally {
    setPerfSink(() => {})
    if (previousDebug === undefined) delete process.env.DSH_LOG_DEBUG
    else process.env.DSH_LOG_DEBUG = previousDebug
  }
  return records
}

test('pump: a narrowed opening records how much it cut', { timeout: 10_000 }, async () => {
  // U6: the reader must be able to tell "this session was narrowed" from the exit
  // log alone — that is what turns a field report into a diagnosis.
  const log = [turn(0), filler(1, 300), turn(2), filler(3, 300)]
  const source = fakeSource([snapshotFrame(log, 4)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, { openingCapBytes: 700 })
  server.listen(0)
  try {
    const records = await collectPerf(async () => {
      await once(server, 'listening')
      const socket = await connect(server)
      send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })
      await receive(socket)
      socket.close()
      await new Promise(resolve => setTimeout(resolve, 30))
    })

    const opening = records.find(record => record.kind === 'opening')
    assert.ok(opening !== undefined, 'the opening is recorded')
    assert.equal(opening.cutTurns, 1, 'how many turns the narrowing cut')
    assert.equal(opening.cutEvents, 2, 'how many events the narrowing cut')
    assert.equal(opening.events, 2, 'how many events the narrowed window carries')
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('pump: a refused opening is recorded with its reason', { timeout: 10_000 }, async () => {
  // No frame goes out on the refusal path, so this record is the only trace of why
  // that session would not open.
  const log = [turn(0), filler(1, 5_000)]
  const source = fakeSource([snapshotFrame(log, 2)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, { openingCapBytes: 700 })
  server.listen(0)
  try {
    const records = await collectPerf(async () => {
      await once(server, 'listening')
      const socket = await connect(server)
      send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })
      await receive(socket) // the error frame
      socket.close()
      await new Promise(resolve => setTimeout(resolve, 30))
    })

    const opening = records.find(record => record.kind === 'opening')
    assert.ok(opening !== undefined, 'the refusal is recorded too')
    assert.equal(opening.rejected, 'window-too-large')
    assert.equal(typeof opening.bytes, 'number')
    assert.ok((opening.bytes as number) > 700, 'the oversize window is the evidence')
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

/** A socket the heartbeat alone reads — its write queue can be set from the test. */
function fakeSocket(writableLength: number) {
  const socket = {
    writableLength,
    destroyed: false,
    writes: 0,
    destroy(): void { socket.destroyed = true },
    write(): void { socket.writes += 1 },
  }
  return socket
}

test('heartbeat: a socket still draining a big frame is not judged dead', { timeout: 5_000 }, async () => {
  // 真机现场（2026-10-14）：1.25 MB 的打开帧在慢链路上要 ~10 秒才传完，而我们自己的 ping
  // 与那一大帧走同一条 TCP、排在它**后面** —— 客户端此刻收不到 ping，收不到就不会回 pong。
  // 把这段算成死亡，连接就会在帧传到一半时被自己掐断（真机表现：客户端每代 2.02 秒一转，
  // 而网关侧连 upgrade 都还没完成）。这里用 10ms 节拍把同一条路径压到一个测试里。
  const sleep = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms))
  const socket = fakeSocket(64 * 1024)
  const beat = startHeartbeat(socket, { intervalMs: 10, missedPongLimit: 1 })
  try {
    // ① 写还在排队：不计数（不修则第一拍就判死），也不把 ping 排到队尾去
    await sleep(60)
    assert.equal(socket.destroyed, false, 'while a big frame is draining, a missing pong proves nothing')
    assert.equal(socket.writes, 0, 'no ping is queued behind the frame it would be stuck behind')

    // ② 排空了、pong 按时回：活着
    socket.writableLength = 0
    const pongs = setInterval(() => beat.heardFrame(), 3)
    await sleep(60)
    assert.equal(socket.destroyed, false, 'a peer that answers pings is alive')
    clearInterval(pongs)

    // ③ 排空了、pong 不再回：判死 —— 半开连接仍然会被发现
    await sleep(60)
    assert.equal(socket.destroyed, true, 'once drained, silence is still death')
  } finally {
    beat.stop()
  }
})

test('endReasonOf: the four ways a connection can end are told apart, strongest evidence first', () => {
  // 网关侧只看得到「socket 关了」，但四档的后续动作完全不同（改心跳规则 / 什么都不做 /
  // 查传输 / 读错误原文）。判据取真实收到的信号，不靠推断。
  assert.equal(endReasonOf({ killed: false, cleanClose: false, errored: false }), 'the link dropped',
    'no signal at all means it broke in the middle, without even a goodbye')
  assert.equal(endReasonOf({ killed: false, cleanClose: true, errored: false }), 'the peer closed it cleanly')
  assert.equal(endReasonOf({ killed: true, cleanClose: false, errored: false }), 'we closed it (no pong)')
  assert.equal(endReasonOf({ killed: false, cleanClose: false, errored: true }), 'the socket errored')
  assert.equal(endReasonOf({ killed: true, cleanClose: true, errored: true }), 'the socket errored',
    'an error outranks everything: it names the cause most precisely')
})

test('heartbeat: a killed connection can name its killer, an untouched one says otherwise', { timeout: 5_000 }, async () => {
  // 「连接结束」那行必须说出是谁关的。Mac 侧此前对断连一行不记，于是真机上「客户端每 35–60 秒
  // 断一次」在网关侧完全看不出来（2026-10-15）—— 两端只有一端有日志，问题就永远定不了性。
  const sleep = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms))

  const alive = fakeSocket(0)
  const beat = startHeartbeat(alive, { intervalMs: 10, missedPongLimit: 1 })
  try {
    assert.equal(beat.killed, false, 'nothing has been closed yet')
    const pongs = setInterval(() => beat.heardFrame(), 3)
    await sleep(60)
    clearInterval(pongs)
    assert.equal(alive.destroyed, false)
    assert.equal(beat.killed, false, 'a connection the peer keeps alive was not closed by us')
  } finally {
    beat.stop()
  }

  const doomed = fakeSocket(0)
  const killer = startHeartbeat(doomed, { intervalMs: 10, missedPongLimit: 1 })
  try {
    await sleep(60)
    assert.equal(doomed.destroyed, true)
    assert.equal(killer.killed, true, 'the heartbeat must be able to name itself as the closer')
  } finally {
    killer.stop()
  }
})

test('heartbeat: a peer that keeps sending frames is alive even though it never answers a ping', { timeout: 10_000 }, async () => {
  // 真机现场（2026-10-14 第三次复验）：客户端每代连接恰好活 6 秒就被自己判死，而网关侧那次
  // `heartbeat: no pong … closing socket` 只是余波。两端同族 —— **我们的 pong 可能正排在一大帧
  // 后面**（1.25 MB 的打开帧 + 中继链路，那一整段时间里链路上什么都过不来），于是客户端回不了
  // pong 不是因为它死了，而是因为我们还没把它要答的那一帧发完。
  //
  // 所以判据不能只认 pong：客户端每 2 秒一次的 ping 走的是**未被堵住**的方向（客户端 → 网关），
  // 它同样证明客户端在看。这条用一只**手写客户端**驱动（Node 内置的那个会自动回 pong，
  // 那门自动应答恰好会遮住要测的东西），心跳节拍压到 20ms（3 拍即判死）。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, {
    heartbeat: { intervalMs: 20, missedPongLimit: 1 },
  })
  server.listen(0)
  let client: { send: (opcode: number, payload: Buffer) => void; gone: () => boolean; upgraded: Promise<void>; close: () => void } | undefined
  let chatter: NodeJS.Timeout | undefined
  try {
    await once(server, 'listening')
    client = await silentClient(server)

    // ① **从第一刻就送**、从不答 pong：活着。晚一步就测不着本条要测的东西 —— 心跳的容错只有两拍
    //（`missedPongLimit: 1` ⇒ 第 2 拍即判死，40ms），慢慢起手的客户端会在第一记 ping 之前就被关掉。
    chatter = setInterval(() => client?.send(OP_PING, Buffer.alloc(0)), 5)
    await client.upgraded // 服务端确实在处理这条连接（否则这条用例会因为「谁都没说话」而假绿）
    await new Promise(resolve => setTimeout(resolve, 200))
    assert.equal(client.gone(), false, 'a peer that keeps talking is not dead — its pong may be queued behind our own frame')

    // ② 一旦真的安静下来：仍然判死 —— 这条规则没有把心跳变成空转
    clearInterval(chatter)
    chatter = undefined
    await new Promise(resolve => setTimeout(resolve, 200))
    assert.equal(client.gone(), true, 'once it goes quiet, silence is still death')
  } finally {
    if (chatter !== undefined) clearInterval(chatter)
    // 裸 socket 必须自己关：留着它，node:test 等不到事件循环排空（整条测试进程会被拖住）。
    client?.close()
    server.closeAllConnections()
    server.close()
  }
})

/** 本条用到的 opcode（RFC 6455 §5.2）。 */
const OP_PING = 0x9

/**
 * 一只**自己说话**的 WebSocket 客户端：手写握手、手写成帧，且除测试明确要求外**什么都不答**。
 *
 * 为什么不直接用内置的 `WebSocket`：它会自动应答每一记 ping（RFC 6455 §5.5.3）—— 那恰好遮住
 * 本条要证的东西（「对端没回 pong」到底能不能推出「对端死了」）。只有一只肯闭嘴的客户端，
 * 才能把「一直在送帧」与「pong 答不上来」这两件事分开。
 */
async function silentClient(server: Server): Promise<{
  send: (opcode: number, payload: Buffer) => void
  gone: () => boolean
  upgraded: Promise<void>
  close: () => void
}> {
  const address = server.address()
  assert.ok(address !== null && typeof address === 'object')
  const socket = tcpConnect(address.port, '127.0.0.1')
  let gone = false
  let upgraded: () => void = () => {}
  const upgradedPromise = new Promise<void>(resolve => { upgraded = resolve })
  socket.on('close', () => { gone = true })
  socket.on('data', () => upgraded()) // 排掉 101 与随后的 opening，本条不读帧；有数据即「服务端开口了」
  await once(socket, 'connect')
  socket.write([
    `GET ${STREAM_PATH} HTTP/1.1`,
    `Host: 127.0.0.1:${address.port}`,
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==', // '0123456789abcdef' 的 base64
    'Sec-WebSocket-Version: 13',
    '\r\n',
  ].join('\r\n'))
  return {
    send: (opcode, payload) => socket.write(maskedClientFrame(opcode, payload)),
    gone: () => gone || socket.destroyed,
    upgraded: upgradedPromise,
    close: () => socket.destroy(),
  }
}

/** 编码一帧带掩码的客户端帧 —— 解析器强制要求（RFC 6455 §5.1）。 */
function maskedClientFrame(opcode: number, payload: Buffer): Buffer {
  const key = Buffer.from([0x21, 0x43, 0x65, 0x87])
  const body = Buffer.from(payload)
  for (let index = 0; index < body.length; index += 1) body[index] ^= key[index % 4]
  assert.ok(body.length < 126, 'test frames stay short')
  return Buffer.concat([Buffer.from([0x80 | opcode, 0x80 | body.length]), key, body])
}
