/**
 * 一条流的测试：从一个 `open` 帧到 `end` 帧。
 *
 * 这些用例只关心流这一层：窗口怎么切、事件怎么转、源说谎时怎么拒绝、一条流失败
 * 时它自己怎么收场。连接的握手与心跳不在这里（那是 `connection.test.ts`），
 * 集合的广播也不在这里（`server.test.ts`）。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { attachStreamHandler } from '../../src/remote/server.ts'
import { setPerfSink } from '../../src/log.ts'
import type { FollowSource } from '../../src/ports/follow.ts'
import type { WireEvent } from '../../src/wire/rpc.ts'
import {
  connect, event, fakeSource, filler, receive, send, snapshotFrame, turn,
} from './harness.ts'

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

test('an explicit maxMessages reaches upstream as its own target, not the default', { timeout: 10_000 }, async () => {
  // 默认目标那条已由上一条钉住；这条问的是**显式尺寸有没有被丢在半路**：
  // `followRequestOf` 解出来的 `maxMessages` 若没传到 `upstreamWindow`，宿主就会按
  // 默认窗口切，而客户端拿到的首屏比它要的更宽 —— 无报错、只是多了。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)

  const socket = await connect(server)
  try {
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1', maxMessages: 7 } })
    await receive(socket) // the opening frame
  } finally {
    socket.close()
    server.closeAllConnections()
    server.close()
  }

  assert.deepEqual(source.requests, [{
    address: { kind: 'session', sessionId: 's1' },
    maxMessages: 14,
    turnWindow: { minMessages: 7, minTurns: 1 },
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

test('one stream failing leaves the other stream on the same connection alive', { timeout: 10_000 }, async () => {
  // 这是「三条流各有故障域」里最该被验证的一条：同一部手机同时开两个会话时，
  // 一个会话的源坏了，另一个不该跟着断。泵的 catch 只折自己那条，
  // `finally` 只清自己的 streamId —— 这条断言把它们钉住。
  const goodLog = [0, 1, 2].map(event)
  const source: FollowSource & { opens: number } = {
    opens: 0,
    async *follow(request, signal) {
      this.opens += 1
      if (request.address.kind !== 'session') throw new Error('test only supports session follows')
      if (request.address.sessionId === 'broken') throw new Error('this session cannot be read')
      for (const frame of [snapshotFrame(goodLog, 3), { type: 'event' as const, event: event(3) }]) {
        if (signal.aborted) return
        yield frame
      }
    },
  }
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    // 先起坏的那条：它应当收到一条 error 帧。
    send(socket, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 'broken' } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.payload as { code: string }).code, 'internal-error')

    // 同一条连接上再起一条好的：连接与它都还活着。
    send(socket, { type: 'open', streamId: 2, payload: { op: 'follow', sessionId: 's1' } })
    const opening = await receive(socket)
    assert.equal(opening.type, 'item', 'the second stream still opens after the first one failed')
    const forwarded = await receive(socket)
    assert.deepEqual((forwarded.payload as { seq?: number }).seq, 3, 'and still forwards its events')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
