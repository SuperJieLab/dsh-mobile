/**
 * 路径路由的边界：什么算一条端点，什么不算。
 *
 * 不算的一律 404 **纯文本** —— 它还没成为一条消息，没有 `rpcId` 可用，包不出信封。
 * 这条分界与流通道那条同源：归不到一条流/一个端点上的东西，是传输层的事。
 *
 * 还有一条：旧的 `POST /rpc` **必须**已经不在 —— 两条路径并存是过渡态，
 * 留着它就成了永久的两套形状。
 *
 * Run: node --test tests/remote/http-routing.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { createRpcListener } from '../../src/remote/http.ts'
import type { CredentialVault } from '../../src/remote/credentials.ts'
import { IdentityRegistry } from '../../src/remote/identity-registry.ts'

const unused = async (): Promise<never> => {
  throw new Error('not used by this test')
}

async function withListener(
  run: (post: (path: string, options?: { body: string }) => Promise<Response>) => Promise<void>,
): Promise<void> {
  const server = createRpcListener({
    sessionPort: { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) },
    vault: { authenticate: () => ({ id: 'test-identity', canAnswer: true }) } as unknown as CredentialVault,
    registry: new IdentityRegistry(),
    writePort: { createSession: unused, promptSession: unused, answerEvent: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: undefined,
  directoryPort: undefined,
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

test('退场端点名在 HTTP 上就是 404 纯文本，没有别名期', async () => {
  await withListener(async (post) => {
    // 名字写在这里是**断言的对象**，不是还在用的端点：判据要能证明它们已被摘掉，
    // 就不得不写出它们。块标记只盖这个数组 —— 出了这一块，这些名字照样会红。
    // terms-ok:start 退场端点名：本数组是断言对象
    const gone = [
      '/api/mobile/listSessions',
      '/api/mobile/permissionCatalog',
      '/api/mobile/permissionSelect',
      // 第 2 期：两条自造读端点被 session/page 与打开帧取代。
      '/api/mobile/snapshot',
      '/api/mobile/page',
      // 第 3 期：两条自造应答端点被一条 $events/result 取代。
      '/api/mobile/approvalAnswer',
      '/api/mobile/questionAnswer',
      // 第 4 期：按名字建组改成按路径注册（workspace/create）。
      '/api/mobile/workspaceCreate',
    ]
    // terms-ok:end
    for (const path of gone) {
      // 404 发生在解 body 之前，所以不带载荷 —— 判的是路径这一层。
      const response = await post(path)
      assert.equal(response.status, 404,
        `「${path}」该 404 —— 留一条别名就等于留两份名字知识，而两份迟早说不同的话`)
      assert.match(response.headers.get('content-type') ?? '', /text\/plain/, '还没成为消息，不给信封')
      assert.equal(await response.text(), 'not found\n')
    }
  })
})

test('合法的两段路径不是 404 —— 正控，防止「全都 404」蒙混过关', async () => {
  await withListener(async (post) => {
    const listed = await post('/api/session/list')
    assert.notEqual(listed.status, 404, '这条路真的在表里，必须走到处理器那一层')
    // 正控：`session/page` 是**换掉**那两条的那一个 —— 只证明旧的没了、
    // 没证明新的在，等于把「分页没了」当成「分页换名了」。
    const paged = await post('/api/session/page', { body: '{}' })
    assert.notEqual(paged.status, 404, 'session/page 必须在表里')
    // 另一半：`$events/result` 是**换掉**那两条的那一个。带 `$` 的名字要能路由 ——
    // 它在 URL 里合法，但拼接与分段都容易写错，所以这条正控直接打它。
    const answered = await post('/api/$events/result', { body: '{}' })
    assert.notEqual(answered.status, 404, '$events/result 必须在表里')
    // 第 4 期的两个：建组换了名字进表，目录浏览是新进表的那一条。
    const created = await post('/api/workspace/create', { body: '{}' })
    assert.notEqual(created.status, 404, 'workspace/create 必须在表里')
    const browsed = await post('/api/directoryPicker/list', { body: '{}' })
    assert.notEqual(browsed.status, 404, 'directoryPicker/list 必须在表里')
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
    const notJson = await post('/api/session/list', { body: 'not json at all' })
    assert.equal(notJson.status, 400)
    assert.match(await notJson.text(), /malformed request/)

    // 2) 是 JSON 但外壳不合格（这里是少了 `rpcId`）：包不出可归属的信封，所以不套信封。
    const noId = await post('/api/session/list', {
      body: JSON.stringify({ type: 'client-request', method: 'session/list', payload: { args: {} } }),
    })
    assert.equal(noId.status, 400)
    assert.match(await noId.text(), /not a client-request/)

    // 3) 超过 1 MiB：413。传输层的守卫，不是协议内的拒绝。
    const huge = await post('/api/session/list', {
      body: JSON.stringify({
        type: 'client-request', rpcId: 'r', method: 'session/list',
        payload: { args: { padding: 'x'.repeat(1_100_000) } },
      }),
    })
    assert.equal(huge.status, 413)
  })
})
