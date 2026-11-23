/**
 * 五个读端点在**新路径**上的行为（判据 3 的读半边、判据 5）。
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

import { createRpcListener, type RpcListenerDeps } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'
import { IdentityRegistry } from '../../src/remote/identity-registry.ts'

const unused = async (): Promise<never> => {
  throw new Error('not used by this test')
}

/** 一份够五个读端点跑的装配：两个会话端口、模型与命令与权限端口都在。 */
const deps = (): RpcListenerDeps => ({
  sessionPort: {
    list: async () => [{
      id: 's-1', title: 'first', createdAt: 1, updatedAt: 5, running: false, blank: false,
    }],
    // 一页历史：宿主的形状，网关只转达（判据在 `page-forward.test.ts`）。
    page: async () => ({ records: [], hasMore: false, cursor: -1 }),
  },
  vault: { authenticate: () => ({ id: 'test-identity', canAnswer: true }) } as unknown as CredentialVault,
  registry: new IdentityRegistry(),
  writePort: { createSession: unused, promptSession: unused, answerEvent: unused },
  modelPort: {
    catalog: async () => ({ groups: [], failures: [] }) as never,
    select: unused,
  },
  commandPort: {
    list: async (agentId: string) => (agentId === 's-1' ? [{ name: 'permission', description: 'switch preset' }] : undefined),
    execute: unused,
  },
  workspacePort: undefined,
  permissionPort: {
    catalog: async () => ({
      options: [{ value: 'ask', name: 'Ask' }],
      defaultOptions: [{ value: 'ask', name: 'Ask' }],
      defaultPreset: 'ask',
    }),
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

test('五个读端点各发一次合法请求全部 ok', async () => {
  const calls: [string, unknown][] = [
    ['/api/session/list', { _request: {} }],
    ['/api/session/page', { request: { address: { kind: 'session', sessionId: 's-1' } } }],
    ['/api/session/modelCatalog', {}],
    ['/api/commands/list', { agentId: 's-1' }],
    ['/api/permissionPresets/catalog', {}],
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
      // 少了 `request` 容器：宿主的参数名就是容器名，少一层就是这条请求坏了。
      // 容器**里面**的字段网关不看（转发）—— 水位合法与否由宿主判，不由网关抄一遍。
      ['/api/session/page', {}, 'invalid-request'],
      ['/api/commands/list', {}, 'unknown-session'],
      ['/api/commands/list', { agentId: 'nope' }, 'unknown-session'],
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

test('判据 3 的另一半：无参的端点在装配缺件时也要回一条拒绝，而不是断开连接', async () => {
  // `session/modelCatalog` 收的是空对象，参数上拒不了它。
  // 但「拒」不等于「参数非法」：端口缺席、数据源抛错都该折成拒绝而不是断开连接。
  // 少了这一条，判据 3 的「每个端点各一次拒绝」就漏掉了「装配缺件」这一整类。
  const broken: RpcListenerDeps = {
    ...deps(),
    modelPort: undefined,
  }
  const server = createRpcListener(broken)
  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    const base = `http://127.0.0.1:${port}`
    const send = async (endpoint: string): Promise<Record<string, unknown>> => {
      const response = await fetch(`${base}/api/${endpoint}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: 'Bearer t' },
        body: JSON.stringify({ type: 'client-request', rpcId: 'r', method: endpoint, payload: { args: {} } }),
      })
      assert.equal(response.status, 200, '已归到端点的事，用信封而不是状态码表达')
      return (await response.json() as { result: Record<string, unknown> }).result
    }

    // `session/list` 现在要 `_request` 这一层容器，所以它不再属于「无需 args 的端点」；
    // 无参的只剩目录那一条，用它证明「装配缺件折成 internal-error」。
    for (const endpoint of ['session/modelCatalog']) {
      const result = await send(endpoint)
      assert.equal(result.ok, false, `「${endpoint}」在这种装配下该拒`)
      const error = result.error as Record<string, unknown>
      assert.equal(error.code, 'internal-error', `「${endpoint}」: 后端故障折成 internal-error`)
      assert.deepEqual(Object.keys(error).sort(), ['code', 'details', 'message'])
    }
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
