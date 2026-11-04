/**
 * 脚本客户端的判据（R8 期2 Task 3：H3）。
 *
 * H3 —— 脚本客户端走**真** WebSocket 完成一次 follow 打开 → 产出 `dev` 记录
 * （含 `kind` / `gen` / `bytes`），且与网关侧的 `gw` 记录同 `seq` 可对齐：
 * 客户端不是另写的一条链路，它消费的就是真泵发出的真帧。
 *
 * Run: node --test tests/tools/client.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { installBench } from '../../tools/bench/host.ts'
import { startFakeUpstream } from '../../tools/bench/upstream.ts'
import { BenchClient } from '../../tools/bench/client.ts'
import { setPerfSink } from '../../src/log.ts'
import type { PerfLike } from '../../tools/bench/analyze.ts'

test('H3: 真 WS 打开 + 事件流 → dev 记录齐全且与 gw 记录同 seq 对齐', { timeout: 15_000 }, async () => {
  const upstream = startFakeUpstream({
    sessions: ['s1'],
    eventRate: 200,
    payloadShape: 'small',
    backlogSeq: 3,
  })
  const bench = await installBench({ sessionController: upstream.controller })

  // 网关侧的 gw 记录：同一个 sink 后门收。
  const gwRecords: PerfLike[] = []
  const previousDebug = process.env.DSH_LOG_DEBUG
  setPerfSink(line => {
    gwRecords.push(JSON.parse(line.slice(line.indexOf(' {') + 1)) as PerfLike)
  })
  process.env.DSH_LOG_DEBUG = '1'

  const client = new BenchClient({ port: bench.port, deviceToken: 'bench-device-token', sessionId: 's1' })
  try {
    await client.start()
    await client.waitForEvents(5, 10_000)
  } finally {
    await client.close()
    bench.teardown()
    setPerfSink(() => {})
    if (previousDebug === undefined) delete process.env.DSH_LOG_DEBUG
    else process.env.DSH_LOG_DEBUG = previousDebug
  }

  const devRecords = client.records()
  const openings = devRecords.filter(record => record.kind === 'opening')
  const events = devRecords.filter(record => record.kind === 'event')

  // 打开一条：字段齐全，seq 是打开的 cursor（backlog 3 → cursor 2）。
  assert.equal(openings.length, 1, 'exactly one opening record')
  assert.equal(openings[0].seg, 'dev')
  assert.equal(openings[0].sessionId, 's1')
  assert.equal(openings[0].gen, 1, 'the connection generation rides the record')
  assert.equal(openings[0].seq, 3, 'the opening records the gateway\'s exclusive cursor as its seq (backlog 3 → cursor 3)')
  assert.ok(openings[0].bytes > 0, 'the opening frame really arrived over the wire')
  assert.ok(openings[0].devRecv <= openings[0].devApply, 'apply happens after recv')

  // 事件 ≥5 条：字段齐全，seq 连续从 backlog 之后走。
  assert.ok(events.length >= 5, `expected at least 5 event records, got ${events.length}`)
  assert.deepEqual(
    events.slice(0, 5).map(record => record.seq),
    [3, 4, 5, 6, 7],
    'live events continue where the backlog ends',
  )
  for (const record of events) {
    assert.ok(record.bytes > 0)
    assert.ok(record.devRecv <= record.devApply)
  }

  // 与网关侧对齐：每个 dev 事件 seq 都有一条同 seq、同 kind 的 gw 记录，反之亦然
  //（测试窗口内两端各记一条，1:1）。
  const gwEvents = gwRecords.filter(record => record.seg === 'gw' && record.kind === 'event')
  const devSeqs = events.map(record => record.seq).sort((a, b) => a - b)
  // `PerfLike` 的字段读出来一律是 `unknown`（分析器要吞任意产物行），而这里要的是
  // 网关自己写下的 `seq` —— 两侧同类记录按它对齐，故此断言一次。
  const gwSeqs = gwEvents.map(record => record.seq as number).sort((a, b) => a - b)
  assert.deepEqual(devSeqs, gwSeqs, 'dev and gw records line up by seq, 1:1')

  // fold 等价物真的在收：镜像 = opening 窗口 + 实时事件，全部进了最简镜像。
  assert.deepEqual(
    client.mirrorSeqs().sort((a, b) => a - b),
    [0, 1, 2, ...devSeqs],
  )
})

test('H3: error 帧被如实记下而不是被吞掉', { timeout: 15_000 }, async () => {
  // 一个开口就抛错的 follow 源：泵必须以 error 帧作答（「坏数据源也是应答」），
  // 脚本客户端把它记下来而不是死等。
  const brokenController = {
    follow: () => { throw new Error('the source refuses') },
  }
  const bench = await installBench({ sessionController: brokenController })
  const client = new BenchClient({ port: bench.port, deviceToken: 'bench-device-token', sessionId: 'nope' })
  try {
    await client.start()
    await client.waitForError(5_000)
    assert.equal(client.lastError()?.code, 'internal-error')
    assert.equal(client.records().length, 0, 'a refused opening produces no dev records')
  } finally {
    await client.close()
    bench.teardown()
  }
})
