/**
 * 路径路由的边界（判据 4）：什么算一条端点，什么不算。
 *
 * 不算的一律 404 **纯文本** —— 它还没成为一条消息，没有 `rpcId` 可用，包不出信封。
 * 这条分界与流通道那条同源：归不到一条流/一个端点上的东西，是传输层的事。
 *
 * 还有一条收口判据（T9b）：旧的 `POST /rpc` **必须**已经不在 —— 两条路径并存是过渡态，
 * 留着它就成了永久的两套形状。
 *
 * Run: node --test tests/remote/http-routing.test.ts
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

async function withListener(
  run: (post: (path: string, options?: { body: string }) => Promise<Response>) => Promise<void>,
): Promise<void> {
  const server = createRpcListener({
    sessionPort: { list: async () => [], read: async () => undefined, readAll: async () => undefined },
    limits: DEFAULT_LIMITS,
    vault: { authenticate: () => true } as unknown as CredentialVault,
    writePort: { createSession: unused, promptSession: unused, answerApproval: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: undefined,
    permissionPort: undefined,
    auditLog: undefined,
  })

  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    const base = `http://127.0.0.1:${port}`
    await run((path, options) => fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer secret-token' },
      body: options?.body ?? JSON.stringify({
        type: 'client-request', rpcId: 'r-1', method: 'x/y', payload: { args: {} },
      }),
    }))
  } finally {
    server.closeAllConnections()
    server.close()
  }
}

test('不是两段的路径都不是端点', async () => {
  await withListener(async (post) => {
    const paths = [
      '/api/foo',              // 一段
      '/api//bar',             // 空段
      '/api/session/modelCatalog/x', // 三段
      '/api/',                 // 只有前缀
    ]
    for (const path of paths) {
      const response = await post(path)
      assert.equal(response.status, 404, `「${path}」不该被当成端点`)
      assert.match(response.headers.get('content-type') ?? '', /text\/plain/, '还没成为消息，不给信封')
      assert.equal(await response.text(), 'not found\n')
    }
  })
})

test('两段但表里没有的名字也是 404 纯文本', async () => {
  await withListener(async (post) => {
    const response = await post('/api/session/nope')
    assert.equal(response.status, 404)
    assert.equal(await response.text(), 'not found\n')
  })
})

test('合法的两段路径不是 404 —— 正控，防止「全都 404」蒙混过关', async () => {
  await withListener(async (post) => {
    const response = await post('/api/mobile/listSessions')
    assert.notEqual(response.status, 404, '这条路真的在表里，必须走到处理器那一层')
  })
})

test('旧的 POST /rpc 已经不存在 —— 它返回 404 纯文本，不是信封', async () => {
  await withListener(async (post) => {
    const response = await post('/rpc')
    assert.equal(response.status, 404, '旧入口必须已经删掉：并存的过渡态不该变成永久')
    assert.match(response.headers.get('content-type') ?? '', /text\/plain/)
    assert.equal(await response.text(), 'not found\n')
  })
})

test('体不是 JSON / 外壳不合格 → 400 纯文本；超限 → 413', async () => {
  await withListener(async (post) => {
    // 1) 体不是 JSON：连「一条消息」都不是。
    const notJson = await post('/api/mobile/listSessions', { body: 'not json at all' })
    assert.equal(notJson.status, 400)
    assert.match(await notJson.text(), /malformed request/)

    // 2) 是 JSON 但外壳不合格（这里是少了 `rpcId`）：包不出可归属的信封，所以不套信封。
    const noId = await post('/api/mobile/listSessions', {
      body: JSON.stringify({ type: 'client-request', method: 'mobile/listSessions', payload: { args: {} } }),
    })
    assert.equal(noId.status, 400)
    assert.match(await noId.text(), /not a client-request/)

    // 3) 超过 1 MiB：413。传输层的守卫，不是协议内的拒绝。
    const huge = await post('/api/mobile/listSessions', {
      body: JSON.stringify({
        type: 'client-request', rpcId: 'r', method: 'mobile/listSessions',
        payload: { args: { padding: 'x'.repeat(1_100_000) } },
      }),
    })
    assert.equal(huge.status, 413)
  })
})
