/**
 * Usage contract tests (M6) — the U table of docs/dev/plans/M6-presentation-layer.md §五.
 *
 * Two promises: the number the phone shows is either the host's own or nothing at
 * all, and a re-read that changes nothing says nothing.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { usageIsTrigger, usageShouldEmit, usageSnapshotOf } from '../../src/contract/usage.ts'

/** A values record shaped the way the projection publishes the two keys. */
function values(pressure: unknown, breakdown?: unknown): Record<string, unknown> {
  return breakdown === undefined
    ? { contextPressure: pressure }
    : { contextPressure: pressure, contextBreakdown: breakdown }
}

test('U1: projectedTokens wins, and only pressureTokens falls back', () => {
  const both = usageSnapshotOf(
    values(
      { projectedTokens: 52_300, pressureTokens: 51_000, contextWindow: 128_000 },
      { systemTokens: 1_000, toolsTokens: 2_000, messageTokens: 49_300 },
    ),
    42,
  )
  assert.equal(both.asOfSeq, 42)
  assert.equal(both.usage?.usedTokens, 52_300)
  assert.equal(both.usage?.contextWindow, 128_000)
  assert.deepEqual(both.usage?.breakdown, { systemTokens: 1_000, toolsTokens: 2_000, messageTokens: 49_300 })

  const sampled = usageSnapshotOf(values({ pressureTokens: 51_000, contextWindow: 128_000 }), 7)
  assert.equal(sampled.usage?.usedTokens, 51_000)
  assert.equal(sampled.usage?.breakdown, undefined, 'no composition was read')
})

test('U2: no numerator or no denominator means no payload — never a zero', () => {
  assert.equal(usageSnapshotOf(values({ contextWindow: 128_000 }), 1).usage, undefined)
  assert.equal(usageSnapshotOf(values({ projectedTokens: 1, pressureTokens: 1 }), 1).usage, undefined)
  assert.equal(usageSnapshotOf({}, 1).usage, undefined)
  assert.equal(usageSnapshotOf({ contextPressure: 'nonsense' }, 1).usage, undefined)
  // The snapshot still exists: the water mark is a fact even where the value is not.
  assert.equal(usageSnapshotOf({}, 9).asOfSeq, 9)
})

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

test('U4: a zero, negative, fractional or non-numeric capacity counts as absent', () => {
  for (const bad of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, '128000', null]) {
    assert.equal(
      usageSnapshotOf(values({ projectedTokens: 10, contextWindow: bad }), 1).usage,
      undefined,
      `contextWindow ${String(bad)} must not become a percentage`,
    )
  }
  // A bad numerator is skipped rather than fatal — the other field may still be usable.
  const skipped = usageSnapshotOf(values({ projectedTokens: 1.5, pressureTokens: 20, contextWindow: 100 }), 1)
  assert.equal(skipped.usage?.usedTokens, 20)
})

test('U5: exactly three event types justify a re-read', () => {
  for (const type of ['assistant/message', 'assistant/attempt', 'request/context']) {
    assert.equal(usageIsTrigger({ type }), true, type)
  }
  for (const type of ['tool/call', 'tool/result', 'turn/start', 'turn/end', 'user/message', 'assistant-stream']) {
    assert.equal(usageIsTrigger({ type }), false, type)
  }
})

test('U7: both keys travel in one payload under one water mark', () => {
  const snapshot = usageSnapshotOf(
    values({ projectedTokens: 10, contextWindow: 100 }, { systemTokens: 1, toolsTokens: 2, messageTokens: 3 }),
    77,
  )
  assert.equal(snapshot.asOfSeq, 77)
  assert.deepEqual(
    Object.keys(snapshot.usage ?? {}).sort(),
    ['breakdown', 'contextWindow', 'usedTokens'],
    'ratio and composition arrive together — a client cannot pair a fresh ratio with a stale split',
  )
  assert.equal(snapshot.usage?.usedTokens, 10, 'and the ratio is unaffected by the split riding along')
})

test('U8: a missing, partial or all-zero composition does not take the ratio with it', () => {
  const missing = usageSnapshotOf(values({ projectedTokens: 10, contextWindow: 100 }), 1)
  assert.equal(missing.usage?.usedTokens, 10)
  assert.equal(missing.usage?.breakdown, undefined)

  const zeros = usageSnapshotOf(
    values({ projectedTokens: 10, contextWindow: 100 }, { systemTokens: 0, toolsTokens: 0, messageTokens: 0 }),
    1,
  )
  assert.equal(zeros.usage?.usedTokens, 10)
  assert.equal(zeros.usage?.breakdown, undefined, 'three zeros are as good as absent')

  const partial = usageSnapshotOf(
    values({ projectedTokens: 10, contextWindow: 100 }, { systemTokens: 1, toolsTokens: 2 }),
    1,
  )
  assert.equal(partial.usage?.breakdown, undefined, 'a partial split would mislead more than it informs')
})
