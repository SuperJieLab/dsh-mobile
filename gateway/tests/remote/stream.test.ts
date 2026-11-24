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
  connect, event, fakeSource, filler, openArgs, receive, send, snapshotFrame, turn,
} from './harness.ts'


test('upgrade + follow: opening, then events, in mux frames', { timeout: 10_000 }, async () => {
  const log = [0, 1, 2].map(event)
  const source = fakeSource([
    snapshotFrame(log, 3),
    { type: 'event', event: event(3) },
    { type: 'event', event: event(4) },
  ])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const opening = await receive(socket)
    assert.equal(opening.type, 'item')
    const payload = opening.value as { type?: string; cursor?: number; hasMore?: boolean; records?: { event?: unknown }[] }
    assert.equal(payload.type, 'snapshot', '打开帧的货物种类')
    assert.equal(payload.cursor, 2, 'cursor 是宿主给的含端上界，原样')
    assert.equal(payload.hasMore, false)
    // 记录是宿主给的那一份 —— 每条包一层判别字段，里面的事件逐字。
    assert.deepEqual(payload.records?.map(record => record.event), log)

    const first = await receive(socket)
    assert.equal((first.value as { type?: string }).type, 'event', '货物种类是判别字段，不是业务事件类型')
    assert.deepEqual((first.value as { event?: unknown }).event, event(3))
    const second = await receive(socket)
    assert.deepEqual((second.value as { event?: unknown }).event, event(4))

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('the follow request asks the host to activate the session — the same as the browser client', { timeout: 10_000 }, async () => {
  // 上游自己的浏览器客户端每次 follow 都带 `activate: true`
  // （`api/session-controller/src/client/transport.ts` 的 `follow`）：在它那里「看一眼会话」
  // 与「这个会话是活的」是同一件事。我们不带的时候，会话只被被动观察 —— `ctx.agents` 里
  // 没有它，于是手机上一切正常，一发消息 / 敲一条命令 / 切一次权限就得到「会话不在」。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    await receive(socket)

    assert.equal(source.requests.length, 1)
    const request = source.requests[0] as { activate?: unknown; assistantStream?: unknown }
    assert.equal(request.activate, true, '打开即激活')
    // 正控：这条请求确实是我们的 follow 构造出来的，而不是夹具里另一个对象。
    assert.equal(request.assistantStream, true)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    const opening = await receive(socket)
    const payload = opening.value as { records: { event: WireEvent }[]; cursor: number; hasMore: boolean }

    assert.equal(payload.records.length, 50, '宿主切的窗口原样到达')
    assert.equal(payload.records[0].event.seq, 7, '窗口起点就是宿主给的那一条')
    assert.equal(payload.hasMore, true, '窗口之前还有 —— 宿主说的')
    assert.equal(payload.cursor, 56, '含端上界原样，不 +1')
    assert.equal(JSON.stringify(payload.records.map(record => record.event)), JSON.stringify(log.slice(7)))
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const opening = await receive(socket)
    assert.equal((opening.value as Record<string, unknown>).cursor, -1, '空日志的含端上界是 -1，原样转达')

    const frame = await receive(socket)
    assert.deepEqual(frame.value, { type: 'assistant-stream', frame: transient.frame })
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
    attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
    server.listen(0)
    try {
      await once(server, 'listening')
      const socket = await connect(server)
      send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

      await receive(socket) // opening
      const refusal = await receive(socket)
      assert.equal(refusal.type, 'error')
      assert.equal((refusal.error as { code: string }).code, 'internal-error')
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('ghost') } })

    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.deepEqual(refusal.error, { code: 'unknown-session', message: 'boom', details: {} })
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    const refusal = await receive(socket)
    assert.equal((refusal.error as { code: string }).code, 'unreadable-session')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close handshake clear the server's heartbeat
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('cancel stops the stream; the pump yields no further frames for it', { timeout: 10_000 }, async () => {
  // A source that would keep yielding forever unless aborted. 把 signal 留下来：
  // cancel 的**确定**证据是「上游收到了 abort」，不是「我们等一会儿没看到帧」。
  let signal: AbortSignal | undefined
  const source: FollowSource = {
    async *follow(_request, abort) {
      signal = abort
      yield snapshotFrame([event(0)], 1)
      let seq = 1
      // 上界只为让**失败路径**能收场：cancel 没传到时，这个循环要自己结束，
      // 否则断言失败之后还留着一条永久定时器，进程不退出（结论变成挂住而不是红）。
      while (!abort.aborted && seq <= 100) {
        yield { type: 'event', event: event(seq) }
        seq += 1
        await new Promise(resolve => setTimeout(resolve, 5))
      }
    },
  }
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  // 客户端在 `finally` 里关：断言失败时它仍在 try 里，不关就会把进程留住，
  // 一条本该报红的判据会变成「挂到超时」。
  let socket: WebSocket | undefined
  try {
    await once(server, 'listening')
    socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    await receive(socket) // opening
    await receive(socket) // event 1

    // 从这一刻起数帧：既证明 abort 传到了上游，也证明泵不再写这条流。
    let afterCancel = 0
    socket.addEventListener('message', () => { afterCancel += 1 })
    send(socket, { type: 'cancel', streamId: 's1' })

    for (let i = 0; i < 50 && signal?.aborted !== true; i++) {
      await new Promise(resolve => setTimeout(resolve, 10))
    }
    assert.equal(signal?.aborted, true, 'cancel 必须中止上游这条流')

    // 先把可能在途的一帧收掉再取基线，然后要求「静默是持续的」—— 只等一次固定时长时，
    // 慢机器上「没来得及发」会被读成「已经停了」。
    await new Promise(resolve => setTimeout(resolve, 100))
    const settled = afterCancel
    await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(afterCancel, settled, 'cancel 之后不该再有新帧（源每 5ms 还在产出）')
  } finally {
    socket?.close()
    server.closeAllConnections()
    server.close()
  }
})

test('the opening carries no model — the projection is the only source', { timeout: 10_000 }, async () => {
  // 打开帧曾经带一份 `model`，投影也带一份：切模型走 `session/selectModel`，投影会变、
  // 打开帧不会 —— 症状是「切了模型但功能条不变」。转发之后打开帧里没有这一格可带。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    const payload = (await receive(socket)).value as Record<string, unknown>
    assert.equal('model' in payload, false, '打开帧里不该再有模型')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('pump: one perf record per forwarded frame — opening and events alike', { timeout: 10_000 }, async () => {
  // 每条过 send 边界的帧都留一条 gw 记录 —— 事件帧带 `seq`
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
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
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

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
    // t2 段（gwRecv → gwSend）是瓶颈指认的依据，1 ms 的整数分辨力
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
  // never inside a turn, where the same span would render two ways.
  const log = [turn(0), filler(1, 300), turn(2), filler(3, 300)]
  const source = fakeSource([snapshotFrame(log, 4)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) }, { openingCapBytes: 900 })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const opening = await receive(socket)
    const payload = opening.value as { records: { event: WireEvent }[]; hasMore: boolean; cursor: number }
    const wire = Buffer.byteLength(JSON.stringify(opening), 'utf8')
    assert.ok(wire <= 900, `the frame fits the cap (was ${wire})`)
    assert.equal(payload.records[0].event.type, 'turn/start', 'the start is a turn boundary')
    assert.equal(payload.records[0].event.seq, 2, 'the earliest turn boundary that still fits')
    assert.equal(payload.hasMore, true, 'the older part stays reachable')
    assert.equal(payload.cursor, 3, 'the water mark does not move when the window narrows')
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) }, { openingCapBytes: 700 })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.error as { code: string }).code, 'window-too-large')
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) }, { openingCapBytes: 0 })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const opening = await receive(socket)
    assert.equal(opening.type, 'item', 'a nonsense cap must not turn into a refusal')
    assert.equal((opening.value as { records: { event: { seq: number } }[] }).records[0].event.seq, 0, 'the default cap applies instead')
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) }, { openingCapBytes: 900 })
  server.listen(0)
  try {
    const records = await collectPerf(async () => {
      await once(server, 'listening')
      const socket = await connect(server)
      send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) }, { openingCapBytes: 700 })
  server.listen(0)
  try {
    const records = await collectPerf(async () => {
      await once(server, 'listening')
      const socket = await connect(server)
      send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    // 先起坏的那条：它应当收到一条 error 帧。
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('broken') } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.error as { code: string }).code, 'internal-error')

    // 同一条连接上再起一条好的：连接与它都还活着。
    send(socket, { type: 'open', streamId: 's2', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    const opening = await receive(socket)
    assert.equal(opening.type, 'item', 'the second stream still opens after the first one failed')
    const forwarded = await receive(socket)
    assert.deepEqual((forwarded.value as { event?: { seq?: number } }).event?.seq, 3, 'and still forwards its events')

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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    assert.equal((await receiveFor(socket, 'a')).type, 'item', '先有第一条流的打开帧')

    send(socket, { type: 'cancel', streamId: 'a' })
    send(socket, { type: 'open', streamId: 'b', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const opening = await receiveFor(socket, 'b')
    assert.equal(opening.type, 'item', '取消之后换号重开：新的打开帧必须到达')
    assert.equal((opening.value as { header?: { id?: string } }).header?.id, 's-1', '打开帧带的是宿主给的头部')
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'dup', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    await receiveFor(socket, 'dup') // 泵还活着（源停在原地）

    // 编号归客户端所有，约定不复用。重复出现说明客户端坏了。
    send(socket, { type: 'open', streamId: 'dup', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const code = await waitForClose(socket)
    // 1008 = 策略违规：帧协议被破坏。带码而不是 destroy（1006）—— 手机侧要靠这个码
    // 分清「被网关判违规」（升级客户端）与「链路掉了」（等重连）。
    assert.equal(code, 1008, `协议违规要带 1008 关；实际 code=${code}`)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U3: two streams on one connection — cancelling one leaves the other alive', { timeout: 10_000 }, async () => {
  const source = lingeringSource()
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    send(socket, { type: 'open', streamId: 'b', endpoint: 'session/follow', payload: { args: openArgs('s2') } })
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'gone', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    await receiveFor(socket, 'gone')
    assert.equal((await receiveFor(socket, 'gone')).type, 'end', '源结束，泵自己收尾')
    await new Promise(resolve => setTimeout(resolve, 30)) // 让 `finally` 里的删除落地

    send(socket, { type: 'cancel', streamId: 'gone' })

    // 连接还在的证据：同一个连接上还能开新流并收到它的打开帧。
    send(socket, { type: 'open', streamId: 'next', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'x', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    await receiveFor(socket, 'x')
    assert.equal((await receiveFor(socket, 'x')).type, 'end')
    await new Promise(resolve => setTimeout(resolve, 50)) // 收尾的删除落地

    // 同号再开必须被当成**新流**接受 —— 条目没被回收的话，这里会变成「重复编号」而关连接。
    send(socket, { type: 'open', streamId: 'x', endpoint: 'session/follow', payload: { args: openArgs('s2') } })
    const opening = await receiveFor(socket, 'x')
    assert.equal(opening.type, 'item', '收尾后编号已被回收，同号可以再开')
    // 打开帧里没有 `sessionId` 了（那是网关自己算的字段）；两条流的区别由请求决定 ——
    // 这一条要说的是「编号被回收、新流真的起了」。
    assert.equal((opening.value as { type?: string }).type, 'snapshot')
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'a', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    await receiveFor(socket, 'a')

    send(socket, { type: 'cancel', streamId: 'a' })
    await source.entered // 泵确定还在（被闸门挡着），条目此刻一定在表里
    assert.equal(source.aborted, 1, '取消送到了泵')

    send(socket, { type: 'open', streamId: 'a', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const code = await waitForClose(socket)
    assert.equal(code, 1008, `取消后同号开流要带 1008 关；实际 code=${code}`)
  } finally {
    source.release() // 放泵退出，别把定时器留给下一轮
    server.closeAllConnections()
    server.close()
  }
})

test('E1a: an open naming no known endpoint is refused on that stream alone', { timeout: 10_000 }, async () => {
  // 分界是**编号在不在手**：这一帧读得出 `e2`，所以坏的是内容、不是这条连接。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'e2', endpoint: 'nosuch/op', payload: { args: {} } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error', '认不出的端点要有一条显式的拒绝，不是静默')
    assert.equal(refusal.streamId, 'e2', '拒绝必须带得上被拒的那条流')
    assert.equal((refusal.error as Record<string, unknown>).code, 'unknown-endpoint')

    // 非空的另一半：拒绝没有升级成断线 —— 同一连接上再开一条真流，它必须真的开起来。
    // 只断言「连接没关」看不出「把新 op 误判成断线」与「正确拒绝」的差别。
    send(socket, { type: 'open', streamId: 'e3', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
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
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    // 先开一条真流：关连接时它确实被一起带走，而不是「反正也没东西可带」。
    send(socket, { type: 'open', streamId: 'e1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })
    await receive(socket)

    send(socket, { type: 'open' }) // 没有编号：读不出它属于哪条流
    const code = await waitForClose(socket)
    assert.equal(code, 1008, `一条归不到任何流的帧要带 1008 关连接；实际 code=${code}`)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('opening 不再带占用 —— 占用量走 control 流', { timeout: 10_000 }, async () => {
  // S4：快照只说「这一段对话是什么」，不再夹一份会过期的读数。覆盖面变了。
  const frame = snapshotFrame([event(0)], 1, {
    projections: {
      asOfSeq: 295,
      values: { contextPressure: { contextWindow: 1_000_000, projectedTokens: 148_807 } },
    },
  })
  const source = fakeSource([frame])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: openArgs('s1') } })

    const payload = (await receive(socket)).value as Record<string, unknown>
    assert.equal(payload.occupancy, undefined, '打开帧里不该再有占用读数')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

