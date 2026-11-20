/**
 * 八个写端点在新路径上的行为（判据 3 的写半边、判据 8）。
 *
 * 写端点比读端点多一条要守的：**拒绝不能变成受理**。`ok` 在这些 op 上的含义是
 * 「已投递 / 已受理 / 已装好」，不是「执行成功」—— 把它们混起来，客户端会在一次
 * 静默失败之后接着做下一件事。
 *
 * Run: node --test tests/protocol/unary-writes.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { DEFAULT_LIMITS } from '../../src/protocol/rpc.ts'
import { createRpcListener, type RpcListenerDeps } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'

const events = [{ type: 'user/message', seq: 0, time: 1, data: {} }]

const deps = (): RpcListenerDeps => ({
  sessionPort: {
    list: async () => [{ id: 's-1', createdAt: 1, updatedAt: 2, running: false, blank: false }],
    read: async (id, since) => (id === 's-1' ? { asOfSeq: since + events.length, events, hasMore: false, staleCursor: false } : undefined),
    readAll: async (id) => (id === 's-1' ? events : undefined),
  },
  limits: DEFAULT_LIMITS,
  vault: { authenticate: () => true } as unknown as CredentialVault,
  writePort: {
    createSession: async () => 's-new',
    promptSession: async (prompt) => (prompt.sessionId === 's-1' ? 'accepted' : 'unknown-session'),
    // 三个结局各给一个 id：已知 → delivered；上游拒 → undelivered；其余 → 没有这条挂起项。
    answerApproval: async (answer) => {
      if (answer.eventId === 'e-1') return 'delivered'
      if (answer.eventId === 'e-reject') return 'undelivered'
      return 'unknown-approval'
    },
  },
  modelPort: {
    catalog: async () => ({ groups: [], failures: [] }) as never,
    select: async (request: { provider: string; model: string }) => (request.model === 'm-1'
      ? { ok: true, selected: { provider: request.provider, model: request.model } }
      : { ok: false, code: 'session/model-unavailable', message: 'not routable' }),
  } as never,
  commandPort: {
    list: async () => [],
    // 只认一条命令：形状对（带斜杠）但名字不在目录里，才是 `unknown-command`。
    execute: async (_sessionId: string, line: string) => (line.startsWith('/permission')
      ? { ok: true, commandId: 'c-1' }
      : { ok: false, code: 'unknown-command', message: 'not a command' }),
  } as never,
  workspacePort: {
    snapshot: () => ({ rows: [], owners: new Map() }) as never,
    create: async (name) => ({ workspaceId: `w-${name}`, title: name, created: true }),
    delete: async () => {},
  },
  permissionPort: {
    catalog: async () => ({}),
    select: async (_sessionId: string, preset: string) => (preset === 'ask'
      ? { ok: true, current: 'ask' }
      : { ok: false, code: 'unknown-preset', message: 'no such preset' }),
  } as never,
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

function resultOf(envelope: Record<string, unknown>): Record<string, unknown> {
  assert.equal(envelope.type, 'server-response')
  return envelope.result as Record<string, unknown>
}

test('八个写端点各发一次合法请求全部 ok，且 value 带着这次的标识', async () => {
  const calls: [string, unknown, Record<string, unknown>][] = [
    ['/api/session/selectModel', { sessionId: 's-1', provider: 'p', model: 'm-1' }, { selected: { provider: 'p', model: 'm-1' } }],
    ['/api/commands/execute', { sessionId: 's-1', line: '/permission ask' }, { commandId: 'c-1' }],
    ['/api/mobile/permissionSelect', { sessionId: 's-1', preset: 'ask' }, { current: 'ask' }],
    ['/api/session/create', {}, { sessionId: 's-new' }],
    ['/api/mobile/workspaceCreate', { name: 'proj' }, { workspaceId: 'w-proj', title: 'proj', created: true }],
    ['/api/workspace/delete', { workspaceId: 'w-1' }, {}],
    ['/api/mobile/approvalAnswer', { eventId: 'e-1', decision: 'allow', answerId: 'a-1' }, { eventId: 'e-1' }],
    ['/api/session/prompt', { sessionId: 's-1', promptId: 'p-1', text: 'hi' }, { sessionId: 's-1' }],
  ]
  await withListener(async (post) => {
    for (const [path, args, expected] of calls) {
      const result = resultOf(await post(path, args))
      assert.equal(result.ok, true, `「${path}」该受理`)
      assert.deepEqual(result.value, expected, `「${path}」回的东西该与旧路径逐字相同`)
    }
  })
})

test('每个写端点的拒绝码与旧路径一致 —— 拒了就不能说 ok', async () => {
  await withListener(async (post) => {
    const cases: [string, unknown, string][] = [
      ['/api/session/selectModel', { sessionId: 's-1', provider: 'p', model: 'm-9' }, 'session/model-unavailable'],
      ['/api/session/selectModel', {}, 'invalid-request'],
      // 没有斜杠是形状不对（`invalid-request`）；有斜杠但不在目录里才是 `unknown-command`。
      ['/api/commands/execute', { sessionId: 's-1', line: 'no slash' }, 'invalid-request'],
      ['/api/commands/execute', { sessionId: 's-1', line: '/nope' }, 'unknown-command'],
      ['/api/commands/execute', {}, 'invalid-request'],
      ['/api/mobile/permissionSelect', { sessionId: 's-1', preset: 'nope' }, 'unknown-preset'],
      ['/api/mobile/permissionSelect', {}, 'invalid-request'],
      ['/api/mobile/workspaceCreate', { name: ' ' }, 'invalid-request'],
      ['/api/workspace/delete', {}, 'invalid-request'],
      ['/api/mobile/approvalAnswer', { eventId: 'e-9', decision: 'allow', answerId: 'a-1' }, 'unknown-approval'],
      ['/api/mobile/approvalAnswer', {}, 'invalid-request'],
      ['/api/session/prompt', { sessionId: 's-9', promptId: 'p-1', text: 'hi' }, 'unknown-session'],
      ['/api/session/prompt', {}, 'invalid-request'],
      ['/api/session/create', { workspaceId: '' }, 'invalid-request'],
    ]
    for (const [path, args, code] of cases) {
      const result = resultOf(await post(path, args))
      assert.equal(result.ok, false, `「${path}」该拒绝`)
      assert.equal((result.error as Record<string, unknown>).code, code, `「${path}」的码`)
    }
  })
})

test('判据 8：未知键不被拒，`promptId` 不改名', async () => {
  await withListener(async (post) => {
    // 多余的键被忽略而不是拒答：`since` / `maxMessages` 这些靠的正是这份宽松，
    // 收紧成「未知键一律拒」会把所有旧客户端一次打死。
    const snapshot = resultOf(await post('/api/mobile/snapshot', { sessionId: 's-1', somethingElse: 1 }))
    assert.equal(snapshot.ok, true, '未知键该被忽略')

    // 上游把这一格叫 `requestId`，我们仍叫 `promptId` —— 本期只换信封，不改 wire 名。
    const withPromptId = resultOf(await post('/api/session/prompt', { sessionId: 's-1', promptId: 'p-1', text: 'hi' }))
    assert.equal(withPromptId.ok, true, '`promptId` 仍是这个名字')

    const withRequestId = resultOf(await post('/api/session/prompt', { sessionId: 's-1', requestId: 'p-1', text: 'hi' }))
    assert.equal(withRequestId.ok, false, '照上游改名会让旧客户端全挂 —— 这一格不许被当成 promptId')
    assert.equal((withRequestId.error as Record<string, unknown>).code, 'invalid-request')
  })
})
