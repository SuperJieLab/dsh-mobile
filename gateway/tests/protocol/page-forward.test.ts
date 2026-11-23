/**
 * `session/page` 转发：一页历史由宿主切，网关只递过去再递回来。
 *
 * 这一期起网关**没有窗口算术**了 —— 上一版的 `pageWindow` 把宿主的规则抄了一遍
 * （消息数、轮边界、上限倍数），宿主改规则时它不会红，症状是「同一屏在 Web UI 与
 * 手机上长度不同」。判据因此只有三类：请求原样到达宿主、应答原样回到客户端、
 * 上游的「没有这个会话」被折成自己的码。
 *
 * 「原样」是双向的：多一格（网关补的默认值、自己算的 `pageStart`）与少一格
 * （只转发它记得的键）都算改了它。
 *
 * Run: node --test tests/protocol/page-forward.test.ts
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { invoke, valueOf } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import { registeredEndpointNames } from '../../src/protocol/unary-endpoints.ts'

/** 客户端该发的请求 —— 上游 `SessionPageRequest` 逐字。 */
const REQUEST = {
  address: { kind: 'session', sessionId: 's-1' },
  throughSeq: 129,
  beforeSeq: 7,
  maxMessages: 500,
  turnWindow: { minMessages: 50, minTurns: 2 },
}

/** 宿主的一页：`{records, hasMore, cursor}`，`cursor` 是**含端**的 `throughSeq`。 */
const HOST_PAGE = {
  records: [{ type: 'event', event: { type: 'user/message', seq: 7, time: 1, data: { text: '早' } } }],
  hasMore: true,
  cursor: 129,
}

/**
 * 一个只认 `page` 的假端口：记下它收到的请求，回一份固定的页。
 *
 * 判据要问的是「网关递了什么」与「网关答了什么」，所以假件不重算任何东西 ——
 * 它照抄宿主那一侧的行为（收到就答），把差异留在网关这一层暴露。
 */
function fakeSessionPort(
  answer: () => Promise<unknown>,
): SessionPort & { requests: Readonly<Record<string, unknown>>[]; calls: number } {
  const requests: Readonly<Record<string, unknown>>[] = []
  return {
    requests,
    get calls() { return requests.length },
    async list() {
      return { items: [] }
    },
    async page(request) {
      requests.push(request)
      return await answer()
    },
  }
}

test('判据 6: the page request reaches the host verbatim and its answer comes back untranslated', async () => {
  const port = fakeSessionPort(async () => HOST_PAGE)
  const result = await invoke('session/page', { request: REQUEST }, { session: port })

  // 请求：**同一个对象**，不是重拼的一份 —— 重拼就会漏掉网关不认识的键。
  assert.deepEqual(port.requests, [REQUEST])
  assert.equal(port.requests[0], REQUEST, '递过去的就是收到的那一份，不是副本')
  // 应答：宿主的键集合（没有 `pageStart`/`asOfSeq`/`sessionId`/`events`）。
  assert.deepEqual(valueOf(result), HOST_PAGE)
  assert.deepEqual(Object.keys(valueOf(result) as object).sort(), ['cursor', 'hasMore', 'records'])
})

test('判据 6: a missing request container is refused before the host is disturbed', async () => {
  const port = fakeSessionPort(async () => HOST_PAGE)
  for (const args of [{}, { address: REQUEST.address }, { request: null }, { request: [] }]) {
    const result = await invoke('session/page', args, { session: port })
    assert.equal(result.ok, false, `${JSON.stringify(args)} 该被拒`)
    assert.equal(result.ok === false && result.error.code, 'invalid-request')
  }
  assert.equal(port.calls, 0, '被拒的请求不该惊动宿主')
})

test('判据 6: a not-found from the host becomes unknown-session, anything else becomes internal-error', async () => {
  const missing = fakeSessionPort(async () => {
    throw Object.assign(new Error('no session "s-9"'), { isDSHRemoteError: true, code: 'session/not-found' })
  })
  const refused = await invoke('session/page', { request: REQUEST }, { session: missing })
  assert.equal(refused.ok, false)
  assert.equal(refused.ok === false && refused.error.code, 'unknown-session')

  // 其余异常由 `invokeEndpoint` 统一折成 internal-error —— 判据同时要求它**不抛**：
  // 抛出去在 HTTP 上就是连接被掐，客户端看到的是一次传输失败而不是一条拒答。
  const broken = fakeSessionPort(async () => { throw new Error('zstd says no') })
  const failed = await invoke('session/page', { request: REQUEST }, { session: broken })
  assert.equal(failed.ok, false)
  assert.equal(failed.ok === false && failed.error.code, 'internal-error')
})

test('判据 14: the table serves session/page and neither mobile reader', () => {
  const names = registeredEndpointNames()
  assert.equal(names.includes('session/page'), true, 'session/page 必须在表里')
  assert.deepEqual(names.filter(name => name === 'mobile/snapshot' || name === 'mobile/page'), [],
    '两条旧读端点已退场 —— 留着别名期就永远不知道谁还在用')
})
