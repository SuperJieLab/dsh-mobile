/**
 * 七个写端点在新路径上的行为。
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

import { remoteEventResultValue } from '../../src/protocol/rpc.ts'
import { createRpcListener, type RpcListenerDeps } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'
import { IdentityRegistry } from '../../src/remote/identity-registry.ts'
import type { Duplex } from 'node:stream'


/**
 * 一条已经登记好的流：本文件的「自己的流」就是它。
 *
 * 本期起审批应答要带 clientId，而归属判定读的是登记表 —— 只给一个字符串不够，
 * 那条流必须真的在表里、并且属于这个身份。
 */
const OWN_CLIENT_ID = 'c-own'
function registryWithOwnStream(): IdentityRegistry {
  const registry = new IdentityRegistry()
  const socket = {} as Duplex
  registry.claim({ id: 'test-identity', canAnswer: true }, socket)
  registry.openStream(OWN_CLIENT_ID, socket)
  return registry
}

const deps = (): RpcListenerDeps => ({
  sessionPort: {
    list: async () => [{ id: 's-1', createdAt: 1, updatedAt: 2, running: false, blank: false }],
    page: async () => ({ records: [], hasMore: false, cursor: -1 }),
  },
  vault: { authenticate: () => ({ id: 'test-identity', canAnswer: true }) } as unknown as CredentialVault,
  registry: registryWithOwnStream(),
  writePort: {
    createSession: async () => 's-new',
    promptSession: async (prompt) => (prompt.sessionId === 's-1' ? 'accepted' : 'unknown-session'),
    // 两个结局各给一个 id：已知 → delivered；上游拒 → undelivered。
    // 「不在暂存表里」不是网关的结局 —— 上游对已结算事件是 no-op。
    answerEvent: async (result) => (result.eventId === 'e-reject' ? 'undelivered' : 'delivered'),
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
    create: async (path) => ({
      workspace: {
        workspaceId: `w-${path}`, path, title: path.split('/').at(-1) ?? path,
        sessionIds: [], createdAt: '2026-11-23T00:00:00.000Z', updatedAt: '2026-11-23T00:00:00.000Z',
      },
      created: true,
    }),
    delete: async () => {},
  },
  directoryPort: undefined,
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

test('$events/result：形状、越权、上游拒各回各的码，成功时回 {ok:true}', async () => {
  await withListener(async (post) => {
    const okArgs = {
      clientId: OWN_CLIENT_ID, eventId: 'e-1',
      outcome: { kind: 'result', value: { answers: [{ id: 'q-1-1', selected: ['A'] }] } },
    }
    const ok = resultOf(await post('/api/$events/result', okArgs))
    assert.deepEqual(ok, { ok: true, value: { ok: true } },
      '内容不进网关的应答 —— 上游的 {ok:true} 原样当 value 交出去')

    const malformed = resultOf(await post('/api/$events/result', { clientId: OWN_CLIENT_ID, eventId: 'e-1' }))
    assert.equal((malformed.error as { code: string }).code, 'invalid-request', '缺 outcome 不是一次应答')

    const intruder = resultOf(await post('/api/$events/result', { ...okArgs, clientId: 'c-someone-else' }))
    assert.equal((intruder.error as { code: string }).code, 'not-owner',
      '归属判定还是那一处 —— 别人的流答不了')

    // 上游拒了：问题还挂着，不能说 ok。
    const refused = resultOf(await post('/api/$events/result', { ...okArgs, eventId: 'e-reject' }))
    assert.equal((refused.error as { code: string }).code, 'internal-error')
  })
})

test('七个写端点各发一次合法请求全部 ok，且 value 带着这次的标识', async () => {
  const calls: [string, unknown, Record<string, unknown>][] = [
    ['/api/session/selectModel', { request: { sessionId: 's-1', provider: 'p', model: 'm-1' } }, { selected: { provider: 'p', model: 'm-1' } }],
    ['/api/commands/execute', { agentId: 's-1', line: '/permission ask', submittedAttachments: [] }, { commandId: 'c-1' }],
    ['/api/session/create', { request: {} }, { sessionId: 's-new' }],
    ['/api/workspace/create', { request: { path: '/Users/x/proj' } }, {
      workspace: {
        workspaceId: 'w-/Users/x/proj', path: '/Users/x/proj', title: 'proj',
        sessionIds: [], createdAt: '2026-11-23T00:00:00.000Z', updatedAt: '2026-11-23T00:00:00.000Z',
      },
      created: true,
    }],
    ['/api/workspace/delete', { request: { workspaceId: 'w-1' } }, {}],
    ['/api/$events/result', { clientId: OWN_CLIENT_ID, eventId: 'e-1', outcome: { kind: 'result', value: 'allowed-once' } }, { ok: true }],
    ['/api/session/prompt', { request: { requestId: 'r-1', sessionId: 's-1', mode: 'queue', content: [{ type: 'text', text: 'hi' }] } }, { accepted: true }],
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
      ['/api/session/selectModel', { request: { sessionId: 's-1', provider: 'p', model: 'm-9' } }, 'session/model-unavailable'],
      ['/api/session/selectModel', {}, 'invalid-request'],
      // 少一层容器同样是畸形：字段一格都没送到。
      ['/api/session/selectModel', { sessionId: 's-1', provider: 'p', model: 'm-1' }, 'invalid-request'],
      // 没有斜杠是形状不对（`invalid-request`）；有斜杠但不在目录里才是 `unknown-command`。
      ['/api/commands/execute', { agentId: 's-1', line: 'no slash', submittedAttachments: [] }, 'invalid-request'],
      ['/api/commands/execute', { agentId: 's-1', line: '/nope', submittedAttachments: [] }, 'unknown-command'],
      ['/api/commands/execute', {}, 'invalid-request'],
      ['/api/workspace/create', { request: { path: ' ' } }, 'invalid-request'],
      ['/api/workspace/create', { path: '/x' }, 'invalid-request'],
      ['/api/workspace/delete', {}, 'invalid-request'],
      ['/api/workspace/delete', { workspaceId: 'w-1' }, 'invalid-request'],
      ['/api/$events/result', { clientId: OWN_CLIENT_ID, eventId: 'e-reject', outcome: { kind: 'result', value: 'rejected' } }, 'internal-error'],
      ['/api/$events/result', {}, 'invalid-request'],
      ['/api/session/prompt', { request: { requestId: 'r-1', sessionId: 's-9', mode: 'queue', content: [{ type: 'text', text: 'hi' }] } }, 'unknown-session'],
      ['/api/session/prompt', {}, 'invalid-request'],
      ['/api/session/create', { request: { workspaceId: '' } }, 'invalid-request'],
      ['/api/session/create', { workspaceId: 'w-1' }, 'invalid-request'],
    ]
    for (const [path, args, code] of cases) {
      const result = resultOf(await post(path, args))
      assert.equal(result.ok, false, `「${path}」该拒绝`)
      assert.equal((result.error as Record<string, unknown>).code, code, `「${path}」的码`)
    }
  })
})

test('未知键不被拒 —— 容器里多一格照样受理', async () => {
  await withListener(async (post) => {
    // 多余的键被忽略而不是拒答：容器里那些宿主认得的键靠的正是这份宽松，
    // 收紧成「未知键一律拒」会把所有旧客户端一次打死。
    const page = resultOf(await post('/api/session/page', {
      request: { address: { kind: 'session', sessionId: 's-1' }, somethingElse: 1 },
    }))
    assert.equal(page.ok, true, '未知键该被忽略')

    const prompt = resultOf(await post('/api/session/prompt', {
      request: {
        requestId: 'r-1', sessionId: 's-1', mode: 'queue',
        content: [{ type: 'text', text: 'hi' }], somethingElse: 1,
      },
    }))
    assert.equal(prompt.ok, true, 'prompt 容器里的未知键同样忽略')

    // 上一期的扁平形状：少一层容器就是畸形，不是「旧键名」。
    const flat = resultOf(await post('/api/session/prompt', { sessionId: 's-1', requestId: 'r-1', text: 'hi' }))
    assert.equal(flat.ok, false)
    assert.equal((flat.error as Record<string, unknown>).code, 'invalid-request')
  })
})

test('可应答标记被读 —— canAnswer 为假的身份答不了审批', async () => {
  // 身份由**参数**构造：生产里没有第二种身份的来源（配对出来的都是 owner），
  // 所以这一支只能在判定层上造出来。见方案「不解决的边界」第 1 条。
  const delivered: string[] = []
  const write = {
    createSession: async () => 's-unused',
    promptSession: async () => 'accepted' as const,
    answerEvent: async (result: { eventId: string }) => {
      delivered.push(result.eventId)
      return 'delivered' as const
    },
  }
  const owners = { ownerOf: () => 'i-owner' }
  const args = { clientId: 'c-1', eventId: 'e-1', outcome: { kind: 'result', value: 'allowed-once' } }

  const muted = await remoteEventResultValue(args, write, { id: 'i-owner', canAnswer: false }, owners)
  assert.equal(muted.ok, false)
  assert.equal(muted.ok ? '' : muted.error.code, 'not-owner')
  assert.deepEqual(delivered, [], '不可应答的身份一个字节都不该投递')

  const allowed = await remoteEventResultValue(args, write, { id: 'i-owner', canAnswer: true }, owners)
  assert.equal(allowed.ok, true)
  assert.deepEqual(delivered, ['e-1'])

  // 同一条流、另一个身份：流在，但不是你的（真端口上的版本在 `tests/index.test.ts`）。
  const intruder = await remoteEventResultValue(args, write, { id: 'i-other', canAnswer: true }, owners)
  assert.equal(intruder.ok, false)
  assert.equal(intruder.ok ? '' : intruder.error.code, 'not-owner')
  assert.deepEqual(delivered, ['e-1'], '越权那次也没到上游')
})
