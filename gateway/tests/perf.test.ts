/**
 * Tests for the perf record exit (src/perf.ts): the line both ends of the link
 * emit and phase 2 consumes. The gate (same DSH_LOG_DEBUG switch as the text
 * exit) and the swappable sink are part of the contract — a record that cannot
 * be switched off or captured is not observable.
 * Run: node --test tests/perf.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { perfEnabled, perfLine, perfRecord, resourceRecord, setPerfSink, type PerfRecord } from '../src/perf.ts'

/** A gw-side record as the pump will emit it (plan §4 contract fields). */
const sample: PerfRecord = {
  seg: 'gw',
  t: 1758000000000,
  sessionId: 's-1',
  seq: 7,
  evTime: 1757999999990,
  gwRecv: 1758000000005,
  gwSend: 1758000000006,
  bytes: 2048,
}

test('perfLine: [dsh] tag, module, and the record as one JSON object', () => {
  const now = new Date('2026-10-13T04:00:00.000Z')
  const line = perfLine('ws', sample, now)
  // 与文本日志同一拼写：时间戳、[dsh][级别][模块] 一个 token、JSON 一个 token。
  const [stamp, tag, json] = line.split(' ')
  // 时间戳不再钉字面量：它现在带本机偏移，钉死等于要求跑测试的机器在某个时区。
  // 要守的是两条与机器无关的性质 —— 形状对、写下的就是那一刻。
  assert.match(stamp, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})$/)
  assert.equal(Date.parse(stamp), now.getTime(), 'perf 行必须与前后的文本日志落在同一刻，否则对照要手算')
  assert.equal(tag, '[dsh][perf][ws]')
  assert.deepEqual(JSON.parse(json), sample)
})

test('perfRecord: gated by the same DSH_LOG_DEBUG switch as the text exit', () => {
  const seen: string[] = []
  setPerfSink((line) => seen.push(line))
  const previous = process.env.DSH_LOG_DEBUG
  try {
    delete process.env.DSH_LOG_DEBUG
    assert.equal(perfEnabled(), false)
    perfRecord('ws', sample)
    assert.equal(seen.length, 0)

    process.env.DSH_LOG_DEBUG = '1'
    assert.equal(perfEnabled(), true)
    perfRecord('ws', sample)
    assert.equal(seen.length, 1)
    assert.ok(seen[0].includes('[dsh][perf][ws]'))
  } finally {
    // 本文件之后不再需要真实输出；换回空 sink 避免污染 stderr。
    setPerfSink(() => {})
    if (previous === undefined) delete process.env.DSH_LOG_DEBUG
    else process.env.DSH_LOG_DEBUG = previous
  }
})

test('resourceRecord: one res record per sample, all five fields present', () => {
  const now = new Date('2026-10-13T04:00:00.000Z')
  const record = resourceRecord(
    { loopLagP50: 0.4, loopLagP99: 3.2, rssMB: 180.5, heapMB: 96.2, wsClients: 2 },
    now,
  )
  assert.deepEqual(record, {
    seg: 'res',
    t: now.getTime(),
    loopLagP50: 0.4,
    loopLagP99: 3.2,
    rssMB: 180.5,
    heapMB: 96.2,
    wsClients: 2,
  })
})
