/**
 * Tests for the perf record exit (src/perf.ts): the line both ends of the link
 * emit and phase 2 consumes. The gate (same DSH_LOG_DEBUG switch as the text
 * exit) and the swappable sink are part of the contract — a record that cannot
 * be switched off or captured is not observable.
 * Run: node --test tests/perf.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { perfEnabled, perfLine, perfRecord, setPerfSink, type PerfRecord } from '../src/perf.ts'

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
  assert.equal(stamp, '2026-10-13T04:00:00.000Z')
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
