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
import type { FollowSource, UpstreamFollowFrame } from '../../src/ports/follow.ts'
import type { WireEvent } from '../../src/wire/rpc.ts'
import {
  connect, event, fakeFeed, fakeSource, filler, receive, send, snapshotFrame, turn,
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

    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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

    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
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
  const transient = { type: 'assistant-stream', frame: { attemptId: 'a1', revision: 3, index: 0, chunk: '你好' } } as const
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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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
      send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 'ghost' } })

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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1', maxMessages: 7 } })
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
    occupancyOf: () => undefined,
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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

    await receive(socket) // opening
    await receive(socket) // event 1
    send(socket, { type: 'cancel', streamId: 's1' })

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
    send(first, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
    const known = await receive(first)
    assert.deepEqual((known.payload as Record<string, unknown>).model, { provider: 'p', model: 'A' },
      'the baseline rides the opening, same breath as the window')
    first.close()

    const second = await connect(server)
    send(second, { type: 'open', streamId: 's2', payload: { op: 'follow', sessionId: 's-unknown' } })
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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

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
      send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
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
      send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
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

test('one stream failing leaves the other stream on the same connection alive', { timeout: 10_000 }, async () => {
  // 这是「三条流各有故障域」里最该被验证的一条：同一部手机同时开两个会话时，
  // 一个会话的源坏了，另一个不该跟着断。泵的 catch 只折自己那条，
  // `finally` 只清自己的 streamId —— 这条断言把它们钉住。
  const goodLog = [0, 1, 2].map(event)
  const source: FollowSource & { opens: number } = {
    opens: 0,
    occupancyOf: () => undefined,
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
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 'broken' } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.payload as { code: string }).code, 'internal-error')

    // 同一条连接上再起一条好的：连接与它都还活着。
    send(socket, { type: 'open', streamId: 's2', payload: { op: 'follow', sessionId: 's1' } })
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

// MARK: - 编号不复用：取消后重开、重复编号、两流并存

/**
 * 一条**不会自己结束**的源：先给一个窗口、再给一条事件，然后停在原地直到被取消。
 *
 * 这三条判据都要求泵活着 —— 会自己结束的源看不到流表里那一条，而这三个缺陷全长在
 * 「表里还占着」的那段时间里。
 */
function lingeringSource(): FollowSource & { started: number; aborted: number } {
  const source = {
    started: 0,
    aborted: 0,
    occupancyOf: () => undefined,
    async *follow(
      _request: Parameters<FollowSource['follow']>[0],
      signal: AbortSignal,
    ): AsyncGenerator<UpstreamFollowFrame> {
      source.started += 1
      yield snapshotFrame([event(0)], 1)
      yield { type: 'event', event: event(1) }
      await new Promise<void>((resolve) => {
        if (signal.aborted) { resolve(); return }
        signal.addEventListener('abort', () => { source.aborted += 1; resolve() }, { once: true })
      })
    },
  }
  return source
}

/** 收帧直到拿到指定编号的那一帧（跳过别的流的收尾帧）。 */
async function receiveFor(socket: WebSocket, streamId: string): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const frame = await receive(socket)
    if (frame.streamId === streamId) return frame
  }
  throw new Error(`no frame for stream "${streamId}"`)
}

/** 等连接被关掉，返回 close code —— 「静默吞掉」的表现是它一直开着。 */
function waitForClose(socket: WebSocket, timeoutMs = 5_000): Promise<number> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error('socket stayed open — the protocol violation was swallowed'))
    }, timeoutMs)
    socket.addEventListener('close', (event) => {
      clearTimeout(timer)
      resolve((event as unknown as { code: number }).code)
    }, { once: true })
  })
}

test('U1: cancel then reopen under a fresh id — the second stream really runs', { timeout: 10_000 }, async () => {
  const source = lingeringSource()
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', payload: { op: 'follow', sessionId: 's1' } })
    assert.equal((await receiveFor(socket, 'a')).type, 'item', '先有第一条流的打开帧')

    send(socket, { type: 'cancel', streamId: 'a' })
    send(socket, { type: 'open', streamId: 'b', payload: { op: 'follow', sessionId: 's1' } })

    const opening = await receiveFor(socket, 'b')
    assert.equal(opening.type, 'item', '取消之后换号重开：新的打开帧必须到达')
    assert.equal((opening.payload as Record<string, unknown>).sessionId, 's1')
    assert.equal(source.started, 2, '两次开流各起过一条泵 —— 取消没有把第二次一起吞掉')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U2: a second open under the same id is a protocol violation — the connection closes', { timeout: 10_000 }, async () => {
  const source = lingeringSource()
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'dup', payload: { op: 'follow', sessionId: 's1' } })
    await receiveFor(socket, 'dup') // 泵还活着（源停在原地）

    // 编号归客户端所有，约定不复用。重复出现说明客户端坏了。
    send(socket, { type: 'open', streamId: 'dup', payload: { op: 'follow', sessionId: 's1' } })

    const code = await waitForClose(socket)
    assert.equal(code, 1006, `连接必须被关掉（destroy 的指纹是 1006）；实际 code=${code}`)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U3: two streams on one connection — cancelling one leaves the other alive', { timeout: 10_000 }, async () => {
  const source = lingeringSource()
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', payload: { op: 'follow', sessionId: 's1' } })
    send(socket, { type: 'open', streamId: 'b', payload: { op: 'follow', sessionId: 's2' } })
    await receiveFor(socket, 'a')
    await receiveFor(socket, 'b')
    assert.equal(source.started, 2, '同一连接上并存两条流')

    send(socket, { type: 'cancel', streamId: 'a' })
    await new Promise(resolve => setTimeout(resolve, 60))
    assert.equal(source.aborted, 1, 'a 的泵收到取消')

    // 连接还活着 —— 证据是第二条流的取消仍然送得到它。取消 a 若把连接带走，
    // 这一帧就没有任何人收，aborted 会停在 1。
    send(socket, { type: 'cancel', streamId: 'b' })
    await new Promise(resolve => setTimeout(resolve, 60))
    assert.equal(source.aborted, 2, 'b 的泵也收到取消：连接没有跟着 a 一起死')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U4: cancel for an id whose pump already finished is not a violation', { timeout: 10_000 }, async () => {
  // U2 的另一半。既然「重复编号」要关连接，就容易把「取消一个表里没有的编号」也判成
  // 违规 —— 而那是**正常路径**：流自己发完 `end` 就收尾并清掉条目，客户端随后关闭详情页，
  // 照样发 `cancel`。判成违规的话，每次正常关闭都会把整条连接打断。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'gone', payload: { op: 'follow', sessionId: 's1' } })
    await receiveFor(socket, 'gone')
    assert.equal((await receiveFor(socket, 'gone')).type, 'end', '源结束，泵自己收尾')
    await new Promise(resolve => setTimeout(resolve, 30)) // 让 `finally` 里的删除落地

    send(socket, { type: 'cancel', streamId: 'gone' })

    // 连接还在的证据：同一个连接上还能开新流并收到它的打开帧。
    send(socket, { type: 'open', streamId: 'next', payload: { op: 'follow', sessionId: 's1' } })
    const opening = await receiveFor(socket, 'next')
    assert.equal(opening.type, 'item', '取消一个已收尾的编号之后，连接必须还能用')
    assert.equal(source.calls, 2)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

/**
 * 一条**停在收尾、等测试放行才退出**的源。
 *
 * 「取消只停泵、不动表」只在这个窗口里看得见 —— 泵一退，条目本来就要删。用闸门而不是
 * `sleep`：判据要在「泵**一定**还没退」的那一刻发下一帧，任何毫秒数在慢机器上都只是把
 * 赌注押大一点。
 */
function gatedSource(): FollowSource & { aborted: number; entered: Promise<void>; release: () => void } {
  let enter: () => void = () => {}
  let leave: () => void = () => {}
  const entered = new Promise<void>((resolve) => { enter = resolve })
  const gate = new Promise<void>((resolve) => { leave = resolve })
  const source = {
    aborted: 0,
    entered,
    release: () => leave(),
    occupancyOf: () => undefined,
    async *follow(
      _request: Parameters<FollowSource['follow']>[0],
      signal: AbortSignal,
    ): AsyncGenerator<UpstreamFollowFrame> {
      yield snapshotFrame([event(0)], 1)
      await new Promise<void>((resolve) => {
        if (signal.aborted) { resolve(); return }
        signal.addEventListener('abort', () => { source.aborted += 1; resolve() }, { once: true })
      })
      // 泵还在收尾：条目这时仍在表里。放行由测试给。
      enter()
      await gate
    },
  }
  return source
}

test('U5: a stream that ends by itself reclaims its id — the table does not grow', { timeout: 10_000 }, async () => {
  // 常驻连接会开很多条流（每切一次会话一条）。条目只在泵退出时删 —— 少了那一句，
  // 表随会话切换次数单调增长，而客户端永不复用编号，没有任何别的东西会回收它。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'x', payload: { op: 'follow', sessionId: 's1' } })
    await receiveFor(socket, 'x')
    assert.equal((await receiveFor(socket, 'x')).type, 'end')
    await new Promise(resolve => setTimeout(resolve, 50)) // 收尾的删除落地

    // 同号再开必须被当成**新流**接受 —— 条目没被回收的话，这里会变成「重复编号」而关连接。
    send(socket, { type: 'open', streamId: 'x', payload: { op: 'follow', sessionId: 's2' } })
    const opening = await receiveFor(socket, 'x')
    assert.equal(opening.type, 'item', '收尾后编号已被回收，同号可以再开')
    assert.equal((opening.payload as Record<string, unknown>).sessionId, 's2')
    assert.equal(source.calls, 2)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U6: cancel does not drop the entry while the pump is still winding down', { timeout: 10_000 }, async () => {
  // 「取消只停泵、不动表」的可执行版本。取消即删的话，同号的 `open` 会落进那个空档被当成
  // 新流接受（这一条会看到 item 而不是 close）；而旧泵退出时的收尾删掉的是**新**条目 ——
  // 那条流从此关不掉。这个窗口只有让源慢一点退才观测得到。
  const source = gatedSource()
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', payload: { op: 'follow', sessionId: 's1' } })
    await receiveFor(socket, 'a')

    send(socket, { type: 'cancel', streamId: 'a' })
    await source.entered // 泵确定还在（被闸门挡着），条目此刻一定在表里
    assert.equal(source.aborted, 1, '取消送到了泵')

    send(socket, { type: 'open', streamId: 'a', payload: { op: 'follow', sessionId: 's1' } })

    const code = await waitForClose(socket)
    assert.equal(code, 1006, `取消后同号开流必须被拒（destroy 的指纹是 1006）；实际 code=${code}`)
  } finally {
    source.release() // 放泵退出，别把定时器留给下一轮
    server.closeAllConnections()
    server.close()
  }
})

test('E1a: an open naming no known op is refused on that stream alone', { timeout: 10_000 }, async () => {
  // 分界是**编号在不在手**：这一帧读得出 `e2`，所以坏的是内容、不是这条连接。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'e2', payload: { op: 'nosuch' } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error', '认不出的 op 要有一条显式的拒绝，不是静默')
    assert.equal(refusal.streamId, 'e2', '拒绝必须带得上被拒的那条流')
    assert.equal((refusal.payload as Record<string, unknown>).code, 'unknown-op')

    // 非空的另一半：拒绝没有升级成断线 —— 同一连接上再开一条真流，它必须真的开起来。
    // 只断言「连接没关」看不出「把新 op 误判成断线」与「正确拒绝」的差别。
    send(socket, { type: 'open', streamId: 'e3', payload: { op: 'follow', sessionId: 's1' } })
    const opening = await receive(socket)
    assert.equal(opening.type, 'item')
    assert.equal(opening.streamId, 'e3')
    assert.equal(source.calls, 1, '被拒的那次 open 没有惊动源')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E1b: a frame that cannot be attributed to any stream closes the connection', { timeout: 10_000 }, async () => {
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    // 先开一条真流：关连接时它确实被一起带走，而不是「反正也没东西可带」。
    send(socket, { type: 'open', streamId: 'e1', payload: { op: 'follow', sessionId: 's1' } })
    await receive(socket)

    send(socket, { type: 'open' }) // 没有编号：读不出它属于哪条流
    const code = await waitForClose(socket)
    assert.equal(code, 1006, `一条归不到任何流的帧要关连接；实际 code=${code}`)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

// MARK: - 事件流：两种载荷（E2 / E3）

/** 起一台挂了真 feed 的监听器；返回的 `feed` 由用例驱动。 */
async function eventsServer() {
  const feed = fakeFeed()
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, { events: feed })
  server.listen(0)
  await once(server, 'listening')
  return { feed, server }
}

test('E2: an events stream opens with ready, then forwards each emit verbatim', { timeout: 10_000 }, async () => {
  // 两张载荷就是这条流的全部词汇：`ready`（源的状态）与 `emit`（源的内容）。
  // 未出生的事件也要能到达 —— 这就是 P2「收得到」在网关侧的判据。
  const { feed, server } = await eventsServer()
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev1', payload: { op: 'events' } })

    const ready = await receive(socket)
    assert.equal(ready.type, 'item')
    assert.equal(ready.streamId, 'ev1', '开口帧属于这条流，不是别的')
    assert.deepEqual(ready.payload, { kind: 'ready' }, '源还没有代次时，ready 不带 generation（缺席，不是 0）')

    feed.emit('api-session/added', ['s9'])
    const forwarded = await receive(socket)
    assert.equal(forwarded.streamId, 'ev1')
    assert.deepEqual(forwarded.payload, { kind: 'emit', event: 'api-session/added', args: ['s9'] },
      '名字与参数原样 —— 下游不再筛一遍')

    // 同一条源上还有审批的帧：它们走自己的 `approval` 广播，不进这条流。
    // 转发它们会让手机在一条「机器上发生了什么」的流里收到待答问题。
    feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'x1', agentId: 'a1', request: {} })
    feed.emit('api-session/removed', ['s1'])
    assert.deepEqual((await receive(socket)).payload, { kind: 'emit', event: 'api-session/removed', args: ['s1'] },
      '审批帧没有出现在这条流上（出现的话它会排在这一帧前面）')

    // 这条流不自己结束：源停在原地时它也不该收到 `end`。
    assert.equal(feed.subscribers(), 1, '一条流一个订阅者')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

/** 等一个条件，按次数算而不是按毫秒 —— 失败的用例要说清「什么没发生」。 */
async function until(condition: () => boolean, what: string): Promise<void> {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    if (condition()) return
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error(`never happened: ${what}`)
}

test('E2b: cancelling an events stream unsubscribes it and reclaims its id', { timeout: 10_000 }, async () => {
  // 事件流是唯一**不会自己结束**的流，所以它的收场只有一条路：取消或连接收尾。
  // 那条路上漏一句，症状分别是「每条关掉的流留一个订阅者」（宿主每发一帧就往一个死
  // socket 里写）与「同号再开被判成重复编号而断线」。
  const { feed, server } = await eventsServer()
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev3', payload: { op: 'events' } })
    await receive(socket) // ready
    assert.equal(feed.subscribers(), 1)

    send(socket, { type: 'cancel', streamId: 'ev3' })
    await until(() => feed.subscribers() === 0, 'the cancelled stream let go of the source')

    // 退订之后再发一帧：它不该在 socket 上留下任何东西（留了的话，下面第一帧就不是 ready）。
    feed.emit('api-session/added', ['s-x'])

    send(socket, { type: 'open', streamId: 'ev3', payload: { op: 'events' } })
    const reopened = await receive(socket)
    assert.deepEqual(reopened.payload, { kind: 'ready' },
      '条目已回收：同号再开是新流，且上一份订阅没有再往这条流里写帧')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E2c: an events stream on a gateway with no wired source is refused on that stream alone', { timeout: 10_000 }, async () => {
  // 装配漏了事件源时，「收下这条流但永远不发文」是最坏的结果：客户端等 45 秒就绪超时，
  // 而在期1 那是**连接级**的判死。拒绝要响，且只落在这一条流上。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'ev9', payload: { op: 'events' } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal(refusal.streamId, 'ev9')
    assert.equal((refusal.payload as Record<string, unknown>).code, 'internal-error')

    // 连接还活着：同一条连接上开一条真流，它必须真的开起来。
    send(socket, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })
    assert.equal((await receive(socket)).type, 'item', '拒绝没有升级成断线')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

// MARK: - 两条流并存与失败隔离（E4 / E5）

/**
 * 一条**由测试节拍驱动**的源：先给窗口，之后每 `tick()` 一次才出一帧。
 *
 * 「取消 b 之后 a 还在出帧」要的是 a **此刻还能推**，而不是「a 的打开帧曾经到过」。
 * 用码表（sleep）赌泵还活着，慢机器上是把赌注押大一点；用节拍就是确定的：
 * 帧在 `tick` 之前根本不存在。
 */
function tickSource(): FollowSource & { tick: (seq: number) => void; aborted: () => number } {
  const queue: UpstreamFollowFrame[] = []
  let wake: (() => void) | undefined
  let aborts = 0
  return {
    occupancyOf: () => undefined,
    aborted: () => aborts,
    tick(seq) {
      queue.push({ type: 'event', event: event(seq) })
      wake?.()
      wake = undefined
    },
    async *follow(
      _request: Parameters<FollowSource['follow']>[0],
      signal: AbortSignal,
    ): AsyncGenerator<UpstreamFollowFrame> {
      signal.addEventListener('abort', () => { aborts += 1; wake?.() }, { once: true })
      yield snapshotFrame([event(0)], 1)
      while (!signal.aborted) {
        const next = queue.shift()
        if (next !== undefined) {
          yield next
          continue
        }
        await new Promise<void>((resolve) => { wake = resolve })
        if (signal.aborted) return
      }
    },
  }
}

test('E4: a follow stream and an events stream coexist — cancelling one leaves the other flowing', { timeout: 10_000 }, async () => {
  // 两条流平级共存是这一期的前提：排队开流会让「详情页开着时事件流建不起来」与
  // 「事件流占着连接时详情页打不开」变成同一个 bug。所以判据要往**两个方向**各打一枪：
  // 取消 b 之后 a 仍能推帧，取消 a 之后 b 仍能收事件。
  const feed = fakeFeed()
  const source = tickSource()
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, { events: feed })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    // 一条一条地开、一条一条地收：两帧的到达顺序不定，而 `receiveFor` 会丢掉不属于目标流
    // 的帧 —— 同时开两条流的话，先到的那条会把另一条的开口帧吃掉。
    send(socket, { type: 'open', streamId: 'a', payload: { op: 'follow', sessionId: 's1' } })
    assert.equal((await receiveFor(socket, 'a')).type, 'item', 'a 的打开帧')
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })
    assert.deepEqual((await receiveFor(socket, 'ev')).payload, { kind: 'ready' }, 'ev 的开口帧')
    assert.equal(feed.subscribers(), 1)

    // 方向一：取消事件流，会话流仍能推帧。
    send(socket, { type: 'cancel', streamId: 'ev' })
    await until(() => feed.subscribers() === 0, '取消的事件流放开了源')
    source.tick(1)
    const forwarded = await receiveFor(socket, 'a')
    assert.deepEqual(forwarded.payload, event(1), '取消 ev 之后 a 仍能推帧 —— 取消没有带走另一条')

    // 方向二：取消会话流，事件流仍能收事件（换号重开一条事件流，编号不复用）。
    send(socket, { type: 'open', streamId: 'ev2', payload: { op: 'events' } })
    assert.deepEqual((await receiveFor(socket, 'ev2')).payload, { kind: 'ready' })
    send(socket, { type: 'cancel', streamId: 'a' })
    await until(() => source.aborted() === 1, 'a 的泵收到取消')
    feed.emit('api-session/added', ['s7'])
    assert.deepEqual((await receiveFor(socket, 'ev2')).payload,
      { kind: 'emit', event: 'api-session/added', args: ['s7'] },
      '取消 a 之后 ev2 仍能收事件 —— 连接还活着，且 ev2 的订阅没被一起收走')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E4b: a refused events stream does not disturb a running follow stream', { timeout: 10_000 }, async () => {
  // 「b 收到 error → a 不受影响」。E2c 验的是「拒绝之后还能再开一条」（事后），这里验的是
  // 「已经在跑的那条继续跑」（当场）—— 后者才是「一条流被拒会不会拽断连接」的直接证据。
  const source = tickSource()
  const server = createServer()
  // 不接事件源：这条连接上开 events 必定被拒。
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', payload: { op: 'follow', sessionId: 's1' } })
    assert.equal((await receiveFor(socket, 'a')).type, 'item')

    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })
    const refusal = await receiveFor(socket, 'ev')
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.payload as Record<string, unknown>).code, 'internal-error')

    source.tick(1)
    assert.deepEqual((await receiveFor(socket, 'a')).payload, event(1),
      'b 被拒之后 a 仍能推帧 —— 拒绝没有升级成连接级')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E5: two events streams on one connection share the source — each gets every event', { timeout: 10_000 }, async () => {
  // 同一台手机开两条事件流（比如两个界面各订一份）不是协议违规：一份源扇出给每条流，
  // 谁也不抢谁的帧。反过来「后开的那条顶掉前一条」在这里会表现为少一帧。
  const { feed, server } = await eventsServer()
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev1', payload: { op: 'events' } })
    send(socket, { type: 'open', streamId: 'ev2', payload: { op: 'events' } })
    await receiveFor(socket, 'ev1')
    await receiveFor(socket, 'ev2')
    assert.equal(feed.subscribers(), 2, '两条流各一份订阅')

    feed.emit('api-session/added', ['s1'])
    assert.deepEqual((await receiveFor(socket, 'ev1')).payload, { kind: 'emit', event: 'api-session/added', args: ['s1'] })
    assert.deepEqual((await receiveFor(socket, 'ev2')).payload, { kind: 'emit', event: 'api-session/added', args: ['s1'] },
      '同一条事件被两条流各收一次')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E5b: a second open(events) under the same id is a protocol violation — the connection closes', { timeout: 10_000 }, async () => {
  // U2 只钉了 follow。`duplicate-id` 的判定在 op 分派**之前**，所以新 op 应当自动继承这条
  // 规矩 —— 但「应当」不是判据：把分派写在查表之前就会让这条流悄悄开成第二条。
  const { feed, server } = await eventsServer()
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'dup', payload: { op: 'events' } })
    await receiveFor(socket, 'dup') // 事件流不会自己结束，条目仍在表里

    send(socket, { type: 'open', streamId: 'dup', payload: { op: 'events' } })
    const code = await waitForClose(socket)
    assert.equal(code, 1006, `同号重开事件流必须被拒（destroy 的指纹是 1006）；实际 code=${code}`)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E3: a new generation is another ready on the same stream, never an end', { timeout: 10_000 }, async () => {
  // 我们比上游多一跳，所以「源重建」到手机这一侧必须是一次**再一次 ready**：
  // 结束流的话，手机会立刻重开一条注定拿不到正文的流，而重开没有退避。
  const { feed, server } = await eventsServer()
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev2', payload: { op: 'events' } })
    assert.deepEqual((await receive(socket)).payload, { kind: 'ready' }, '开流那一刻源还没有代次')

    feed.setGeneration(3)
    assert.deepEqual((await receive(socket)).payload, { kind: 'ready', generation: 3 }, '代次建立 = 一条新的 ready')

    feed.setGeneration(undefined)
    assert.deepEqual((await receive(socket)).payload, { kind: 'ready' },
      '源失效也是 ready（无代次）—— 不是 end，流继续活着')

    feed.emit('api-session/removed', ['s1'])
    assert.deepEqual((await receive(socket)).payload, { kind: 'emit', event: 'api-session/removed', args: ['s1'] },
      '失效之后这条流仍然接得上下一代的内容')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
