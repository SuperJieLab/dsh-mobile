/**
 * 新路径上的身份闸与审计（判据 9）。
 *
 * 三件事各守一个失败方式：
 * - 无票打普通端点 → 401，且**体仍是 `server-response`**（回旧信封会让客户端在两条
 *   路径上各有一套解码）。
 * - 无票打 `mobile/pair` → 不该因缺票被拒。要求「拿票的端点先有票」是死锁，
 *   而它的症状是「全新的手机永远配不上对」。
 * - 写端点在新路径上也要进审计。这一条最不重要又最容易漏：`http.ts` 原来从请求体读
 *   旧 `op` 去判写操作，信封一换那个字段就没了 —— 少记是静默的。
 *
 * Run: node --test tests/remote/http-auth.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { DEFAULT_LIMITS } from '../../src/protocol/rpc.ts'
import { WRITE_OPS } from '../../src/audit.ts'
import { writeEndpointLegacyOps } from '../../src/protocol/unary-endpoints.ts'
import { createRpcListener, type RpcListenerDeps } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'
import type { AuditEntry } from '../../src/audit.ts'

const records: Omit<AuditEntry, 'at'>[] = []

const deps = (): RpcListenerDeps => ({
  sessionPort: {
    list: async () => [],
    read: async () => undefined,
    readAll: async () => undefined,
  },
  limits: DEFAULT_LIMITS,
  vault: {
    authenticate: (header: string | undefined) => header === 'Bearer good',
    pair: (code: unknown) => (code === '123456'
      ? { ok: true, deviceToken: 'd-1' }
      : { ok: false, reason: '配对码不对' }),
    refresh: (token: unknown) => (token === 'd-1'
      ? { ok: true, accessToken: 'a-1', expiresAt: 1, deviceToken: 'd-1' }
      : { ok: false }),
  } as unknown as CredentialVault,
  writePort: {
    createSession: async () => 's-new',
    promptSession: async () => 'accepted',
    answerApproval: async () => 'delivered',
  },
  modelPort: undefined,
  commandPort: undefined,
  workspacePort: undefined,
  permissionPort: undefined,
  auditLog: { append: (entry: Omit<AuditEntry, 'at'>) => { records.push(entry) } } as never,
})

async function withListener(run: (post: (path: string, args: unknown, token?: string) => Promise<Response>) => Promise<void>): Promise<void> {
  records.length = 0
  const server = createRpcListener(deps())
  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    const base = `http://127.0.0.1:${port}`
    await run((path, args, token = 'Bearer good') => fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: token },
      body: JSON.stringify({
        type: 'client-request',
        rpcId: 'r-1',
        method: path.slice('/api/'.length),
        payload: { args },
      }),
    }))
  } finally {
    server.closeAllConnections()
    server.close()
  }
}

test('无票打普通端点 → 401，体仍是 server-response 的 unauthenticated', async () => {
  await withListener(async (post) => {
    const response = await post('/api/session/modelCatalog', {}, 'Bearer stale')
    assert.equal(response.status, 401)
    const body = await response.json() as Record<string, unknown>
    assert.equal(body.type, 'server-response')
    assert.equal(body.rpcId, 'r-1')
    const result = body.result as Record<string, unknown>
    assert.equal(result.ok, false)
    assert.equal((result.error as Record<string, unknown>).code, 'unauthenticated')
  })
})

test('无票打 mobile/pair 不被缺票拒 —— 拿票的端点要先有票就是死锁', async () => {
  await withListener(async (post) => {
    const response = await post('/api/mobile/pair', { code: '123456' }, '')
    assert.equal(response.status, 200, '配对本身不该因缺票被拒')
    const result = (await response.json() as { result: Record<string, unknown> }).result
    assert.equal(result.ok, true)
    assert.deepEqual(result.value, { deviceToken: 'd-1' })

    const wrong = await post('/api/mobile/pair', { code: '000000' }, '')
    assert.equal(wrong.status, 200, '拒绝用信封表达，不用状态码')
    const wrongResult = (await wrong.json() as { result: Record<string, unknown> }).result
    assert.equal(wrongResult.ok, false)
    assert.equal((wrongResult.error as Record<string, unknown>).code, 'invalid-pairing-code')
  })
})

test('无票打 mobile/refresh 同理，且续期被拒是 unauthenticated', async () => {
  await withListener(async (post) => {
    const ok = await post('/api/mobile/refresh', { deviceToken: 'd-1' }, '')
    const okResult = (await ok.json() as { result: Record<string, unknown> }).result
    assert.equal(okResult.ok, true)

    const refused = await post('/api/mobile/refresh', { deviceToken: 'nope' }, '')
    const refusedResult = (await refused.json() as { result: Record<string, unknown> }).result
    assert.equal((refusedResult.error as Record<string, unknown>).code, 'unauthenticated')
  })
})

test('写端点在新路径上进审计，且记的是旧 op 名', async () => {
  await withListener(async (post) => {
    await post('/api/session/prompt', { sessionId: 's-1', promptId: 'p-1', text: 'hi' })
    assert.equal(records.length, 1, '一次写 op 恰好一条审计')
    assert.equal(records[0].op, 'session-prompt', '审计的 op 字段沿用旧名，历史文件才是同一套词汇')
    assert.equal(records[0].result, 'ok')

    await post('/api/mobile/snapshot', { sessionId: 's-1' })
    assert.equal(records.length, 1, '读 op 不进审计 —— 审计回答「谁改了什么」')
  })
})

test('端点表的写标记与 audit 的旧清单不许漂', async () => {
  // 过渡期两张清单并存：新路径读端点表的 `write`，旧路径读 `WRITE_OPS`。
  // 漂了的症状是「同一个写操作在一条路径上被记、另一条没记」，而它静默。
  assert.deepEqual([...writeEndpointLegacyOps()].sort(), [...WRITE_OPS].sort(),
    '端点表里标了写的端点，其旧 op 名必须与 audit.ts 的清单一致')
})
