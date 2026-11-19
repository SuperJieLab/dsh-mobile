/**
 * `usageIsTrigger`：哪些事件值得重读投影（U5）。
 *
 * 「该发哪一帧」那一半已随 `usage` 帧一起退役 —— 现在由 control 流按 `asOfSeq`
 * 比较前后两份投影，取分子规则在客户端（`UsageView`）。这一层只剩「要不要重读」。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { usageIsTrigger } from '../../src/protocol/usage.ts'

test('U5: exactly three event types justify a re-read', () => {
  for (const type of ['assistant/message', 'assistant/attempt', 'request/context']) {
    assert.equal(usageIsTrigger({ type }), true, type)
  }
  for (const type of ['tool/call', 'tool/result', 'turn/start', 'turn/end', 'user/message', 'assistant-stream']) {
    assert.equal(usageIsTrigger({ type }), false, type)
  }
})
