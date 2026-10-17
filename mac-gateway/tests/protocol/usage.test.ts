/**
 * 用量帧的发送判定（U3 / U5）—— 什么时候值得重读投影、什么时候值得发一帧。
 *
 * 输入快照用真实的转换函数生成（`upstream/usage.ts`），不手写对象：判的是「比较」，
 * 而比较的对象必须是线上真会出现的形状。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { usageIsTrigger, usageShouldEmit } from '../../src/protocol/usage.ts'
import { usageSnapshotOf } from '../../src/upstream/usage.ts'

/** A values record shaped the way the projection publishes the two keys. */
function values(pressure: unknown, breakdown?: unknown): Record<string, unknown> {
  return breakdown === undefined
    ? { contextPressure: pressure }
    : { contextPressure: pressure, contextBreakdown: breakdown }
}

test('U3: an unchanged value earns no frame, and a value that disappears does', () => {
  const first = usageSnapshotOf(values({ projectedTokens: 10, contextWindow: 100 }), 5)
  const same = usageSnapshotOf(values({ projectedTokens: 10, contextWindow: 100 }), 6)
  assert.equal(usageShouldEmit(undefined, first), true, 'the first snapshot of a stream is news')
  assert.equal(usageShouldEmit(first, same), false, 'a later seq carrying the same value is not')

  const changed = usageSnapshotOf(values({ projectedTokens: 11, contextWindow: 100 }), 7)
  assert.equal(usageShouldEmit(same, changed), true)

  const gone = usageSnapshotOf(values({ contextWindow: 100 }), 8)
  assert.equal(usageShouldEmit(changed, gone), true, 'nothing displayable is itself a change')
  assert.equal(usageShouldEmit(gone, usageSnapshotOf(values({ contextWindow: 100 }), 9)), false)

  // The composition is a value of its own: the two keys update independently, so the
  // ratio can stand still while the split moves. Comparing the ratio alone would
  // swallow it and leave a stale split beside a fresh number.
  const split = usageSnapshotOf(
    values({ projectedTokens: 51_000, contextWindow: 128_000 }, { systemTokens: 1, toolsTokens: 2, messageTokens: 3 }),
    10,
  )
  const resplit = usageSnapshotOf(
    values({ projectedTokens: 51_000, contextWindow: 128_000 }, { systemTokens: 2, toolsTokens: 2, messageTokens: 3 }),
    11,
  )
  assert.equal(split.usage?.usedTokens, resplit.usage?.usedTokens, 'the ratio itself did not move')
  assert.equal(usageShouldEmit(split, resplit), true, 'only the split moved — still news')
})

test('U5: exactly three event types justify a re-read', () => {
  for (const type of ['assistant/message', 'assistant/attempt', 'request/context']) {
    assert.equal(usageIsTrigger({ type }), true, type)
  }
  for (const type of ['tool/call', 'tool/result', 'turn/start', 'turn/end', 'user/message', 'assistant-stream']) {
    assert.equal(usageIsTrigger({ type }), false, type)
  }
})
