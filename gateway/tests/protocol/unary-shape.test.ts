/**
 * 一元调用的新路径（判据 1）：`POST /api/<命名空间>/<方法>` 上的一次读。
 *
 * 最要紧的一条是「值仍然由装配函数产出」—— 只断言 200 与 `result.ok` 的话，把
 * `listSessionsOf` 换成一个就地拼的假对象也照样绿。所以这里把 HTTP 拿到的 `value`
 * 与**直调装配函数**的结果逐字段比一次：传输层只该搬，不该改。
 *
 * Run: node --test tests/protocol/unary-shape.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { DEFAULT_LIMITS, listSessionsOf } from '../../src/protocol/rpc.ts'
import { createRpcListener, type RpcListenerDeps } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'
import { IdentityRegistry } from '../../src/remote/identity-registry.ts'

const unused = async (): Promise<never> => {
  throw new Error('not used by this test')
}

/** 一个空会话表 + 一个空的工作空间注册表；身份恒真。 */
function deps(): RpcListenerDeps {
  return {
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
    vault: { authenticate: () => ({ id: 'test-identity', canAnswer: true }) } as unknown as CredentialVault,
    registry: new IdentityRegistry(),
    writePort: { createSession: unused, promptSession: unused, answerApproval: unused, answerQuestion: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: {
      snapshot: () => ({ rows: [{ id: 'w-1', title: 'group' }], owners: new Map([['s-1', 'w-1']]) }) as never,
      create: unused,
      delete: async () => {},
    },
    permissionPort: undefined,
    auditLog: undefined,
  }
}

/** 起一个真监听器，并把它用的那套依赖一并交出来（比值的判据要用同一套）。 */
async function withListener(
  run: (post: (path: string, body: unknown) => Promise<Response>, deps: RpcListenerDeps) => Promise<void>,
): Promise<void> {
  const built = deps()
  const server = createRpcListener(built)

  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    const base = `http://127.0.0.1:${port}`
    await run((path, body) => fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer secret-token' },
      body: JSON.stringify(body),
    }), built)
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

test('新路径回 server-response，值就是装配函数的产出', async () => {
  await withListener(async (post, built) => {
    const fresh = await post('/api/mobile/listSessions', request('mobile/listSessions'))
    assert.equal(fresh.status, 200)
    assert.match(fresh.headers.get('content-type') ?? '', /application\/json/)

    const envelope = await fresh.json() as Record<string, unknown>
    assert.deepEqual(Object.keys(envelope).sort(), ['result', 'rpcId', 'type'])
    assert.equal(envelope.type, 'server-response')
    assert.equal(envelope.rpcId, 'r-1', '应答要把请求那个 id 原样带回')

    const result = envelope.result as Record<string, unknown>
    assert.equal(result.ok, true)

    // 直调装配函数：同一套端口，时钟固定。`serverTime` 是「这一刻」的读数，
    // 走 HTTP 那次用的是真时钟，所以比之前把它抹掉 —— 要证的是「别的字段没被改」。
    const direct = await listSessionsOf(built.sessionPort, built.workspacePort, () => 0)
    const value = result.value as Record<string, unknown>
    assert.equal(typeof value.serverTime, 'number', '应答该带这个读数')
    const withoutClock = (body: Record<string, unknown>): Record<string, unknown> => {
      const { serverTime: _time, ...rest } = body
      return rest
    }
    assert.deepEqual(withoutClock(value), withoutClock(direct as Record<string, unknown>),
      '传输层只该搬：HTTP 拿到的值必须与装配函数直调逐字相同')
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

test('打一条不存在的端点 → 404 纯文本，不是信封', async () => {
  await withListener(async (post) => {
    // 这是「客户端打到一个新网关没有的端点」的全部现场：404，没有 `rpcId` 可归属，
    // 所以也包不出信封（判据 4）。手机侧把它译成「两边版本不一致」。
    const response = await post('/api/session/nope', request('session/nope'))
    assert.equal(response.status, 404)
    assert.match(response.headers.get('content-type') ?? '', /text\/plain/)
    assert.equal(await response.text(), 'not found\n')
  })
})
