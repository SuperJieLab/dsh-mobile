/**
 * 一元调用的新路径（判据 1）：`POST /api/<命名空间>/<方法>` 上的一次读。
 *
 * 最要紧的一条是「换壳不换值」—— 只断言 200 与 `result.ok` 的话，把 `list-sessions`
 * 的装配顺手改错也照样绿。所以这里把新旧两条路径的**业务字段**逐字比一次。
 *
 * Run: node --test tests/protocol/unary-shape.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { DEFAULT_LIMITS } from '../../src/protocol/rpc.ts'
import { createRpcListener } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'

const unused = async (): Promise<never> => {
  throw new Error('not used by this test')
}

/** 起一个真监听器：一个空会话表、一个空的工作空间注册表、身份恒真。 */
async function withListener(run: (post: (path: string, body: unknown) => Promise<Response>) => Promise<void>): Promise<void> {
  const server = createRpcListener({
    sessionPort: {
      list: async () => [{
        id: 's-1',
        title: 'first',
        createdAt: 1,
        updatedAt: 5,
        running: false,
        blank: false,
      }],
      read: async () => undefined,
      readAll: async () => undefined,
    },
    limits: DEFAULT_LIMITS,
    vault: { authenticate: () => true } as unknown as CredentialVault,
    writePort: { createSession: unused, promptSession: unused, answerApproval: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: {
      snapshot: () => ({ rows: [{ id: 'w-1', title: 'group' }], owners: new Map([['s-1', 'w-1']]) }) as never,
      create: unused,
      delete: async () => {},
    },
    permissionPort: undefined,
    auditLog: undefined,
  })

  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    const base = `http://127.0.0.1:${port}`
    await run((path, body) => fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer secret-token' },
      body: JSON.stringify(body),
    }))
  } finally {
    server.closeAllConnections()
    server.close()
  }
}

const request = (method: string, rpcId = 'r-1'): unknown => ({
  type: 'client-request',
  rpcId,
  method,
  payload: { args: {} },
})

test('新路径回 server-response，且业务字段与旧路径逐字相同', async () => {
  await withListener(async (post) => {
    const fresh = await post('/api/mobile/listSessions', request('mobile/listSessions'))
    assert.equal(fresh.status, 200)
    assert.match(fresh.headers.get('content-type') ?? '', /application\/json/)

    const envelope = await fresh.json() as Record<string, unknown>
    assert.deepEqual(Object.keys(envelope).sort(), ['result', 'rpcId', 'type'])
    assert.equal(envelope.type, 'server-response')
    assert.equal(envelope.rpcId, 'r-1', '应答要把请求那个 id 原样带回')

    const result = envelope.result as Record<string, unknown>
    assert.equal(result.ok, true)

    const legacy = await post('/rpc', { v: 2, op: 'list-sessions' })
    const legacyBody = await legacy.json() as Record<string, unknown>
    // `serverTime` 是「这一刻」的读数，两次调用不该相等；其余字段必须逐字相同 ——
    // 逐字比全部的话，这一条会因为时钟而红，而它想证明的是「装配没被换掉」。
    const fields = (body: Record<string, unknown>): Record<string, unknown> => {
      const { v: _v, ok: _ok, serverTime: _time, ...rest } = body
      return rest
    }
    assert.deepEqual(fields(result.value as Record<string, unknown>), fields(legacyBody),
      '换的是壳，值的装配不该跟着换')
    assert.equal(typeof (result.value as Record<string, unknown>).serverTime, 'number',
      '两条路径都该带这个读数')
  })
})

test('请求里的 method 与路径不一致 → invalid-request，且不落到处理器', async () => {
  await withListener(async (post) => {
    const response = await post('/api/mobile/listSessions', request('mobile/snapshot'))
    assert.equal(response.status, 200, '已归到一条端点的事，用信封而不是状态码表达')
    const body = await response.json() as { result: { ok: boolean; error: { code: string; details: unknown } } }
    assert.equal(body.result.ok, false)
    assert.equal(body.result.error.code, 'invalid-request')
    assert.deepEqual(body.result.error.details, { method: 'mobile/snapshot', endpoint: 'mobile/listSessions' })
  })
})
