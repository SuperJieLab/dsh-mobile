/**
 * 写载荷的编解码（两端共守的那一半）：畸形载荷一律拒绝，不做归一化。
 *
 * 写路径比读路径严：畸形决定被静默执行，等于凭猜测运行一条远程命令。所以这里
 * 每条用例都问「坏输入会不会被猜成一个能用的决定」，而不只是「好输入能不能解析」。
 *
 * `handle` 怎么分派在 `protocol/`；幂等已经不在网关（上游对已结算事件是 no-op），
 * 所以这里也没有「重放表怎么记账」。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { remoteEventResultOf, sessionPromptOf } from '../../src/wire/write.ts'

test('$events/result: well-formed payload parses all three outcome kinds', () => {
  assert.deepEqual(
    remoteEventResultOf({
      clientId: 'c-1', eventId: 'e-1',
      outcome: { kind: 'result', value: 'allowed-once' },
    }),
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'result', value: 'allowed-once' } },
  )
  // `value` 缺席合法：结算成 undefined。
  assert.deepEqual(
    remoteEventResultOf({ clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'result' } }),
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'result' } },
  )
  assert.deepEqual(
    remoteEventResultOf({ clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'next' } }),
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'next' } },
  )
  assert.deepEqual(
    remoteEventResultOf({
      clientId: 'c-1', eventId: 'e-1',
      outcome: { kind: 'rejected', error: { name: 'AbortError', message: 'gone', code: 'x' } },
    }),
    {
      clientId: 'c-1', eventId: 'e-1',
      outcome: { kind: 'rejected', error: { name: 'AbortError', message: 'gone', code: 'x' } },
    },
  )
})

test('$events/result: malformed payloads are refused, not normalized', () => {
  for (const bad of [
    {},
    // 归属的键：缺了它不是「当没带」，是整条不合格。
    { eventId: 'e-1', outcome: { kind: 'result', value: 'x' } },
    { clientId: '', eventId: 'e-1', outcome: { kind: 'result' } },
    { clientId: 'c-1', eventId: 9, outcome: { kind: 'result' } },
    { clientId: 'c-1', eventId: 'e-1' },
    { clientId: 'c-1', eventId: 'e-1', outcome: {} },
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'oops' } },
    { clientId: 'c-1', eventId: 'e-1', outcome: 'result' },
    // `result` 显式给 undefined：线上会变成「没带 value」，两种语义静默合并。
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'result', value: undefined } },
    // `rejected` 缺 error / error 缺 name。
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'rejected' } },
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'rejected', error: { message: 'm' } } },
    { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'rejected', error: { name: 'E', message: '' } } },
  ]) {
    assert.equal(remoteEventResultOf(bad as Record<string, unknown>), undefined, JSON.stringify(bad))
  }
})

test('session-prompt: the request container is the shape, five keys inside', () => {
  const args = {
    request: {
      requestId: 'r-1',
      sessionId: 's-1',
      mode: 'steer',
      content: [{ type: 'text', text: ' hi ' }],
      clientTimeZone: 'Asia/Shanghai',
    },
  }
  assert.deepEqual(sessionPromptOf(args), {
    requestId: 'r-1',
    sessionId: 's-1',
    mode: 'steer',
    content: [{ type: 'text', text: ' hi ' }],
    clientTimeZone: 'Asia/Shanghai',
  })

  // 时区可缺；缺了就不补。缺 = 没有这一格（显式给 undefined 是另一回事，见下一条）。
  const { clientTimeZone: _ignored, ...rest } = args.request
  const noZone = { request: rest }
  assert.deepEqual(sessionPromptOf(noZone), {
    requestId: 'r-1', sessionId: 's-1', mode: 'steer', content: [{ type: 'text', text: ' hi ' }],
  })
})

test('session-prompt: malformed payloads are refused, not normalized', () => {
  const ok = { requestId: 'r-1', sessionId: 's-1', mode: 'queue', content: [{ type: 'text', text: 'hi' }] }
  for (const bad of [
    // 上一期的扁平形状：少一层容器。
    { sessionId: 's-1', text: 'hi', promptId: 'p' },  // terms-ok: 断言对象：上一期的扁平形状
    {},
    { request: {} },
    { request: { ...ok, requestId: '' } },
    { request: { ...ok, sessionId: 9 } },
    { request: { ...ok, mode: 'now' } },
    { request: { ...ok, content: [] } },
    { request: { ...ok, content: [{ type: 'text', text: '   ' }] } },
    { request: { ...ok, content: [{ type: 'image', data: 'x' }] } },
    { request: { ...ok, content: [{ type: 'text' }] } },
    { request: { ...ok, clientTimeZone: '' } },
    { request: { ...ok, clientTimeZone: 8 } },
  ]) {
    assert.equal(sessionPromptOf(bad as Record<string, unknown>), undefined, JSON.stringify(bad))
  }
})
