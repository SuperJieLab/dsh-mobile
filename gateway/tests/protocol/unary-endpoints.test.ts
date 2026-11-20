/**
 * 六个读端点在**新路径**上的行为（判据 3 的读半边、判据 5）。
 *
 * 两条口径：
 * - 每个端点各发一次合法请求必须 `ok:true` —— 少一个登记的名字就是「客户端打得到、
 *   服务端不认识」，症状是 404，而 404 在别处也出现，从状态码看不出来。
 * - 拒绝码与**旧路径逐字相同** —— 迁移的是信封，不是语义；改了这一层就等于顺手
 *   改了客户端的补救动作。
 *
 * Run: node --test tests/protocol/unary-endpoints.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { DEFAULT_LIMITS } from '../../src/protocol/rpc.ts'
import { createRpcListener, type RpcListenerDeps } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'

const unused = async (): Promise<never> => {
  throw new Error('not used by this test')
}

const events = [
  { type: 'user/message', seq: 0, time: 1, data: {} },
  { type: 'assistant/message', seq: 1, time: 2, data: {} },
]

/** 一份够六个读端点跑的装配：会话有两条事件、模型与命令与权限端口都在。 */
const deps = (): RpcListenerDeps => ({
  sessionPort: {
    list: async () => [{
      id: 's-1', title: 'first', createdAt: 1, updatedAt: 5, running: false, blank: false,
    }],
    read: async (id, since, limit) => {
      if (id !== 's-1') return undefined
      const page = events.filter(event => event.seq >= since).slice(0, limit)
      const last = page.at(-1)
      return {
        asOfSeq: last === undefined ? since : last.seq + 1,
        events: page,
        hasMore: page.length < events.filter(event => event.seq >= since).length,
        staleCursor: false,
      }
    },
    readAll: async (id) => (id === 's-1' ? events : undefined),
  },
  limits: DEFAULT_LIMITS,
  vault: { authenticate: () => true } as unknown as CredentialVault,
  writePort: { createSession: unused, promptSession: unused, answerApproval: unused },
  modelPort: {
    catalog: async () => ({ groups: [], failures: [] }) as never,
    select: unused,
  },
  commandPort: {
    list: async (id) => (id === 's-1' ? [{ name: 'permission', description: 'switch preset' }] : undefined),
    execute: unused,
  },
  workspacePort: undefined,
  permissionPort: {
    catalog: async (id) => (id === 's-1' ? { current: 'ask', options: [{ value: 'ask', name: 'Ask' }] } : {}),
    select: unused,
  },
  auditLog: undefined,
})

async function withListener(run: (post: (path: string, args: unknown) => Promise<Record<string, unknown>>) => Promise<void>): Promise<void> {
  const server = createRpcListener(deps())
  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    const base = `http://127.0.0.1:${port}`
    await run(async (path, args) => {
      const response = await fetch(`${base}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: 'Bearer secret-token' },
        body: JSON.stringify({
          type: 'client-request',
          rpcId: 'r-1',
          method: path.slice('/api/'.length),
          payload: { args },
        }),
      })
      return await response.json() as Record<string, unknown>
    })
  } finally {
    server.closeAllConnections()
    server.close()
  }
}

/** 取 `result` 那一格，并断言请求被受理过（信封形状对）。 */
function resultOf(envelope: Record<string, unknown>): Record<string, unknown> {
  assert.equal(envelope.type, 'server-response')
  assert.equal(envelope.rpcId, 'r-1')
  return envelope.result as Record<string, unknown>
}

test('六个读端点各发一次合法请求全部 ok', async () => {
  const calls: [string, unknown][] = [
    ['/api/mobile/listSessions', {}],
    ['/api/mobile/snapshot', { sessionId: 's-1' }],
    ['/api/mobile/page', { sessionId: 's-1' }],
    ['/api/session/modelCatalog', {}],
    ['/api/commands/list', { sessionId: 's-1' }],
    ['/api/mobile/permissionCatalog', { sessionId: 's-1' }],
  ]
  await withListener(async (post) => {
    for (const [path, args] of calls) {
      const result = resultOf(await post(path, args))
      assert.equal(result.ok, true, `「${path}」该受理`)
      assert.ok(result.value !== undefined, `「${path}」成功后要有 value 那一格`)
    }
  })
})

test('拒绝码与旧路径逐字相同 —— 迁移的是信封，不是语义', async () => {
  await withListener(async (post) => {
    const cases: [string, unknown, string][] = [
      ['/api/mobile/snapshot', {}, 'unknown-session'],
      ['/api/mobile/snapshot', { sessionId: 'nope' }, 'unknown-session'],
      ['/api/mobile/page', {}, 'unknown-session'],
      ['/api/mobile/page', { sessionId: 'nope' }, 'unknown-session'],
      ['/api/commands/list', {}, 'unknown-session'],
      ['/api/commands/list', { sessionId: 'nope' }, 'unknown-session'],
      ['/api/mobile/permissionCatalog', {}, 'unknown-session'],
    ]
    for (const [path, args, code] of cases) {
      const result = resultOf(await post(path, args))
      assert.equal(result.ok, false, `「${path}」该拒绝`)
      const error = result.error as Record<string, unknown>
      assert.equal(error.code, code, `「${path}」的拒绝码该与旧路径一致`)
      assert.deepEqual(Object.keys(error).sort(), ['code', 'details', 'message'],
        '新信封的失败恒为三键 —— 这一格是 S3 要的同形')
    }
  })
})

test('判据 5：畸形 beforeSeq 退化为最新窗口，不拒答', async () => {
  await withListener(async (post) => {
    const result = resultOf(await post('/api/mobile/page', { sessionId: 's-1', beforeSeq: 'oops' }))
    assert.equal(result.ok, true, '畸形 beforeSeq 是合法请求，至多多付一个窗口')
    const value = result.value as Record<string, unknown>
    assert.equal(typeof value.asOfSeq, 'number')
    assert.ok(Array.isArray(value.events))
  })
})
