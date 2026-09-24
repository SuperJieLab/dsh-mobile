/**
 * Contract tests for the backwards-window arithmetic (contract/window.ts): the
 * reference spelling of the window rule. The rule's behaviour through `page` and
 * the follow opening is covered by rpc.test.ts and mux.test.ts end to end — this
 * file pins the shared spelling itself.
 * Run: node --test tests/contract/window.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { upstreamWindow } from '../../src/contract/window.ts'

test('upstreamWindow: the reference spelling of our one-target window rule', () => {
  // The reference splits the rule into a floor it may stop after and a ceiling it
  // must stop at; ours takes one target and derives the ceiling. Here the two
  // spellings meet (spec §8.5 B6 二次裁决).
  assert.deepEqual(upstreamWindow(50), {
    maxMessages: 100,
    turnWindow: { minMessages: 50, minTurns: 1 },
  })
  assert.deepEqual(upstreamWindow(7), {
    maxMessages: 14,
    turnWindow: { minMessages: 7, minTurns: 1 },
  })
})
