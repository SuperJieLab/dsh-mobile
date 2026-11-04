/**
 * 写载荷的编解码（两端共守的那一半）：畸形载荷一律拒绝，不做归一化。
 *
 * 写路径比读路径严：畸形决定被静默执行，等于凭猜测运行一条远程命令。所以这里
 * 每条用例都问「坏输入会不会被猜成一个能用的决定」，而不只是「好输入能不能解析」。
 *
 * `handle` 怎么分派、重放表怎么记账都不在这里 —— 前者在 `protocol/`，后者在
 * `upstream/`（那张表是幂等承诺的实现，不是形状）。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { approvalAnswerOf, sessionPromptOf } from '../../src/wire/write.ts'

test('approval-answer: well-formed payload parses', () => {
  assert.deepEqual(
    approvalAnswerOf({ eventId: 'a', decision: 'allow', answerId: 'k' }),
    { eventId: 'a', decision: 'allow', answerId: 'k' },
  )
})

test('approval-answer: malformed payloads are refused, not normalized', () => {
  for (const bad of [
    {},
    { eventId: 'a', decision: 'allow' },
    { eventId: 'a', decision: 'ALLOW', answerId: 'k' },
    { eventId: '', decision: 'allow', answerId: 'k' },
    { eventId: 'a', decision: 'allow', answerId: 7 },
  ]) {
    assert.equal(approvalAnswerOf(bad as Record<string, unknown>), undefined, JSON.stringify(bad))
  }
})

test('session-prompt: well-formed payload parses; blank text refused', () => {
  assert.deepEqual(
    sessionPromptOf({ sessionId: 's', text: ' hi ', promptId: 'p' }),
    { sessionId: 's', text: ' hi ', promptId: 'p' },
  )
  for (const bad of [
    { sessionId: 's', text: '   ', promptId: 'p' },
    { sessionId: 's', text: 'hi' },
    { sessionId: '', text: 'hi', promptId: 'p' },
  ]) {
    assert.equal(sessionPromptOf(bad as Record<string, unknown>), undefined, JSON.stringify(bad))
  }
})
