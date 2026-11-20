/**
 * 一元信封的两半：客户端发进来的、网关回出去的（判据 2）。
 *
 * 断言的是「键集合恰好」而不是「某个字段在」—— 多一格（例如残留的 `v`）与少一格
 * 在解析上都表现为「能读」，只有逐格对账才分得出来。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import {
  UNARY_ENDPOINT_NAMES,
  encodeServerResponse,
  parseClientRequest,
} from '../../src/wire/unary.ts'

const valid = JSON.stringify({
  type: 'client-request',
  rpcId: 'r-1',
  method: 'session/modelCatalog',
  payload: { args: {} },
})

test('合法请求解析出四格，args 原样带出', () => {
  const request = parseClientRequest(valid)
  assert.ok(request !== undefined, '四条都在就该解析成功')
  assert.deepEqual(Object.keys(request).sort(), ['method', 'payload', 'rpcId', 'type'])
  assert.equal(request.type, 'client-request')
  assert.equal(request.rpcId, 'r-1')
  assert.equal(request.method, 'session/modelCatalog')
  assert.deepEqual(request.payload, { args: {} })
})

test('多一格就拒 —— 残留的 v 不能被容忍', () => {
  const withVersion = JSON.stringify({
    v: 2,
    type: 'client-request',
    rpcId: 'r-1',
    method: 'session/modelCatalog',
    payload: { args: {} },
  })
  assert.equal(parseClientRequest(withVersion), undefined, '多一格说明对端还在说旧协议')
})

test('四格里缺任何一格都拒', () => {
  const drops = ['type', 'rpcId', 'method', 'payload'] as const
  for (const key of drops) {
    const body = JSON.parse(valid) as Record<string, unknown>
    delete body[key]
    assert.equal(
      parseClientRequest(JSON.stringify(body)),
      undefined,
      `缺 ${key} 就该拒 —— 缺格与「值为空」在解析上长得一样`,
    )
  }
})

test('payload 只许一格 args；args 必须是对象', () => {
  const extra = JSON.stringify({
    type: 'client-request',
    rpcId: 'r-1',
    method: 'session/modelCatalog',
    payload: { args: {}, extra: 1 },
  })
  assert.equal(parseClientRequest(extra), undefined, 'payload 多一格说明参数放错了层')

  for (const args of ['null', '3', '"x"', '[]']) {
    const body = `{"type":"client-request","rpcId":"r-1","method":"session/modelCatalog","payload":{"args":${args}}}`
    assert.equal(parseClientRequest(body), undefined, `args 是 ${args} 时不该成形`)
  }
})

test('不是 JSON、不是对象、rpcId 为空串 —— 都拒', () => {
  for (const body of ['', 'not json', '[]', '3', 'null']) {
    assert.equal(parseClientRequest(body), undefined, `「${body}」不是一条请求`)
  }
  const emptyRpcId = JSON.stringify({
    type: 'client-request',
    rpcId: '',
    method: 'session/modelCatalog',
    payload: { args: {} },
  })
  assert.equal(parseClientRequest(emptyRpcId), undefined, 'rpcId 是关联键，空串等于没有')
})

test('应答：成功与失败各是 server-response 的三格', () => {
  const ok = JSON.parse(
    encodeServerResponse('r-1', { ok: true, value: { items: [] } }),
  ) as Record<string, unknown>
  assert.deepEqual(Object.keys(ok).sort(), ['result', 'rpcId', 'type'])
  assert.equal(ok.type, 'server-response')
  assert.equal(ok.rpcId, 'r-1')
  assert.deepEqual(ok.result, { ok: true, value: { items: [] } })

  const failed = JSON.parse(
    encodeServerResponse('r-1', {
      ok: false,
      error: { code: 'unknown-session', message: 'no such session', details: {} },
    }),
  ) as Record<string, unknown>
  const result = failed.result as Record<string, unknown>
  assert.equal(result.ok, false)
  assert.deepEqual(
    Object.keys(result.error as Record<string, unknown>).sort(),
    ['code', 'details', 'message'],
    '失败对象恰好三键 —— 少一格客户端读不到详情，多一格是对端多给了语义',
  )
})

test('端点名表：十六个，无重复，都带命名空间', () => {
  assert.equal(UNARY_ENDPOINT_NAMES.length, 16, '十四个业务端点 + pair / refresh')
  assert.equal(new Set(UNARY_ENDPOINT_NAMES).size, 16, '重名会让表在后一个上静默覆盖')
  for (const name of UNARY_ENDPOINT_NAMES) {
    assert.match(name, /^[a-z$][\w$]*\/[A-Za-z][\w]*$/, `「${name}」不是两段的端点名`)
  }
  assert.ok(UNARY_ENDPOINT_NAMES.includes('session/modelCatalog'), '照上游的那七个在表里')
  assert.ok(UNARY_ENDPOINT_NAMES.includes('mobile/listSessions'), '自造的九个在表里')
})
