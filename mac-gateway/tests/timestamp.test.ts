/**
 * 日志时间戳：形状、极性、毫秒补零，以及「写下的时刻就是那一刻」。
 *
 * 与 iOS 侧同一组样本（`ios/tests/LogTimestampTests.swift`）—— 两份实现靠字面量对齐，
 * 不靠「记得同步」。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { logTimestamp } from '../src/timestamp.ts'
import { createLogger, mintRequestId, runWithRequestId, setLogSink } from '../src/log.ts'

/** 捕获日志行。与 `workspace-root.test.ts` 同一个手法：替换去向，用完还原。 */
function captureLogLines(): { lines: string[]; restore: () => void } {
  const lines: string[] = []
  const previous = setLogSink((_level, _module, line) => { lines.push(line) })
  return { lines, restore: () => { setLogSink(previous) } }
}

/** 一个不带毫秒的时刻，便于手算：2026-11-02T06:58:12.188Z。 */
const INSTANT = new Date(1_793_602_692_188)

test('east of UTC keeps the wall clock and says so with +08:00', () => {
  assert.equal(logTimestamp(INSTANT, 480), '2026-11-02T14:58:12.188+08:00')
})

test('west of UTC subtracts and says so with -05:00', () => {
  assert.equal(logTimestamp(INSTANT, -300), '2026-11-02T01:58:12.188-05:00')
})

test('a zero offset is written Z, not +00:00', () => {
  assert.equal(logTimestamp(INSTANT, 0), '2026-11-02T06:58:12.188Z')
})

test('a non-whole-hour offset keeps its minutes', () => {
  // 印度 +05:30：把偏移当整数小时算会在这种地方静默错半小时。
  assert.equal(logTimestamp(INSTANT, 330), '2026-11-02T12:28:12.188+05:30')
})

test('milliseconds are always three digits', () => {
  assert.equal(logTimestamp(new Date(1_793_602_692_005), 0), '2026-11-02T06:58:12.005Z')
  assert.equal(logTimestamp(new Date(1_793_602_692_000), 0), '2026-11-02T06:58:12.000Z')
})

test('the written stamp denotes the same instant it was given', () => {
  for (const offset of [0, 480, -300, 330, -720]) {
    const stamp = logTimestamp(INSTANT, offset)
    assert.equal(Date.parse(stamp), INSTANT.getTime(),
      `偏移 ${offset} 之后写成 ${stamp} —— 它必须还能换算回同一刻，否则那一行就是错的`)
  }
})

test('the shape is the one the contract documents', () => {
  // 这条正则与 `dev/contract/logging.md` 里写的是同一条，iOS 侧也跑同一组样本。
  for (const offset of [0, 480, -300]) {
    assert.match(logTimestamp(INSTANT, offset), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})$/)
  }
})

test('the default offset comes from the instant, so production needs no argument', () => {
  // 不传偏移时取本机时区：这条只证明「默认值存在且形状对」，不去假定跑测试的机器在哪个时区。
  assert.match(logTimestamp(INSTANT), /(Z|[+-]\d{2}:\d{2})$/)
  assert.equal(Date.parse(logTimestamp(INSTANT)), INSTANT.getTime())
})

// -- 请求标记 ---------------------------------------------------------------

/**
 * 关联标记：同一次请求的若干行共用一个 id，不同请求不同。
 *
 * 这一组判据守的是「能不能把一次操作的日志拼回来」—— 网关并发服务多个请求，
 * 没有标记时只能靠时间接近去猜。
 */
test('lines written inside one request carry the same marker', async () => {
  const captured = captureLogLines()
  try {
    const log = createLogger('workspace')
    await runWithRequestId('abc12345', async () => {
      log.info('first')
      await new Promise(resolve => setImmediate(resolve))
      log.warn('second')
    })
    log.info('outside')

    const markers = captured.lines.map(line => /\[req=([^\]]+)\]/.exec(line)?.[1] ?? null)
    assert.deepEqual(markers, ['abc12345', 'abc12345', null],
      '同一次请求的两行要同 id；作用域外的那一行不该有标记')
  } finally {
    captured.restore()
  }
})

test('two concurrent requests keep their own markers', async () => {
  const captured = captureLogLines()
  try {
    const log = createLogger('workspace')
    await Promise.all([
      runWithRequestId('aaaa1111', async () => {
        await new Promise(resolve => setImmediate(resolve))
        log.info('from A')
      }),
      runWithRequestId('bbbb2222', async () => {
        log.info('from B')
      }),
    ])

    const byText = new Map(captured.lines.map(line => [line.includes('from A') ? 'A' : 'B', line]))
    assert.match(byText.get('A') ?? '', /\[req=aaaa1111\]/,
      '并发时标记不能串 —— 串了就等于没有，而且错得看不出来')
    assert.match(byText.get('B') ?? '', /\[req=bbbb2222\]/)
  } finally {
    captured.restore()
  }
})

test('a minted id is short and non-empty', () => {
  const id = mintRequestId()
  assert.equal(id.length, 8)
  assert.notEqual(mintRequestId(), id, '两次铸出的不该相同')
})
