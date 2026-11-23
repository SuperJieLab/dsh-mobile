/**
 * 端点表：四个名字与它们的请求校验。
 *
 * 判据是「名字 → 泵的种类」这一层映射，与帧形状无关 —— 帧在哪一格带这个名字，
 * 由 `mux.ts` 的 `OpenFrame` 负责。
 *
 * 四个名字都是上游的：`session/follow`（每会话一条）、`session/control`、`$events`
 * 与 `workspace/follow`（各每连接一条，且都没有入参）。认不出的名字与「名字对、参数不对」
 * 是两个不同的失败：前者是两端说不到一处，后者是同一处说错了内容 —— 错误码
 * 分开，排障时才知道该看哪一端。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { ENDPOINTS, resolveEndpoint } from '../../src/wire/endpoints.ts'

test('resolveEndpoint: 四个名字各自落到自己的泵', () => {
  const address = { kind: 'session', sessionId: 's-1' }
  assert.deepEqual(
    resolveEndpoint('session/follow', { request: { address } }),
    { ok: true, kind: 'follow', request: { address } },
  )
  assert.deepEqual(
    resolveEndpoint('session/follow', {
      request: { address, maxMessages: 20, turnWindow: { minMessages: 5, minTurns: 2 }, activate: true },
    }),
    { ok: true, kind: 'follow', request: { address, maxMessages: 20, turnWindow: { minMessages: 5, minTurns: 2 }, activate: true } },
  )
  assert.deepEqual(resolveEndpoint('session/control', {}), { ok: true, kind: 'control', request: undefined })
  assert.deepEqual(resolveEndpoint('$events', {}), { ok: true, kind: 'events', request: undefined })
  assert.deepEqual(resolveEndpoint('workspace/follow', {}), { ok: true, kind: 'workspace', request: undefined })
})

test('resolveEndpoint: 名字不在表里是 unknown-endpoint，与参数无关', () => {
  for (const endpoint of ['foo/bar', 'session/approvals', 'events/session', '', 42, null, undefined]) {
    assert.deepEqual(resolveEndpoint(endpoint, {}), { ok: false, code: 'unknown-endpoint' }, String(endpoint))
  }
})

test('resolveEndpoint: 名字对、参数不对是 invalid-args', () => {
  const address = { kind: 'session', sessionId: 's-1' }
  const bad = [
    // 上一期的扁平形状：少一层 `request` 容器、地址也是裸的 `sessionId`。
    ['session/follow', { address }],
    ['session/follow', { sessionId: 's-1' }],
    ['session/follow', {}],
    ['session/follow', { request: {} }],
    ['session/follow', { request: { address: { kind: 'session', sessionId: '' } } }],
    ['session/follow', { request: { address: { kind: 'session', sessionId: 1 } } }],
    ['session/follow', { request: { address: { kind: 'subagent', sessionId: 's-1' } } }],
    ['session/follow', { request: { address, maxMessages: 0 } }],
    ['session/follow', { request: { address, maxMessages: 1.5 } }],
    ['session/follow', { request: { address, turnWindow: { minMessages: 5 } } }],
    ['session/follow', { request: { address, assistantStream: false } }],
    ['session/control', { sessionId: 's-1' }],
    ['$events', { anything: true }],
    // 组流也没有入参：多一个键说明客户端以为它有参数，该在开流时就拒。
    ['workspace/follow', { sessionId: 's-1' }],
    ['workspace/follow', []],
    ['workspace/follow', null],
    ['$events', []],
    ['$events', null],
  ] as const
  for (const [endpoint, args] of bad) {
    assert.deepEqual(resolveEndpoint(endpoint, args), { ok: false, code: 'invalid-args' }, `${endpoint} ${JSON.stringify(args)}`)
  }
})

test('resolveEndpoint: 名字清单就是四个，没有第五个', () => {
  assert.deepEqual(Object.values(ENDPOINTS),
    ['session/follow', 'session/control', '$events', 'workspace/follow'])
})
