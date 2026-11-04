/**
 * 网关指标：`GET /metrics` 的格式与接线。
 *
 * 最要紧的是「计数真的接上了吗」那一条 —— 只测 `Metrics.render()` 自己的话，
 * `http.ts` 里少那一行也能全绿，而那意味着这一页永远是空的。
 *
 * Run: node --test tests/metrics.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import type { AddressInfo } from 'node:net'

import { Metrics } from '../src/metrics.ts'
import { DEFAULT_LIMITS } from '../src/protocol/rpc.ts'
import { createRpcListener } from '../src/remote/http.ts'
import type { CredentialVault } from '../src/remote/credentials.ts'
import { PROTOCOL_VERSION } from '../src/wire/rpc.ts'

const sample = {
  loopLagP50: 0.004,
  loopLagP99: 0.021,
  rssMB: 64.5,
  heapMB: 12.25,
  wsClients: 3,
}

// ── 渲染 ─────────────────────────────────────────────────────────────

test('a counter renders with its help, type, and labels', () => {
  const metrics = new Metrics()
  metrics.count('dsh_rpc_requests_total', { op: 'session-prompt', result: 'ok' })

  const text = metrics.render()
  assert.match(text, /^# HELP dsh_rpc_requests_total /m)
  assert.match(text, /^# TYPE dsh_rpc_requests_total counter$/m)
  assert.match(text, /^dsh_rpc_requests_total\{op="session-prompt",result="ok"\} 1$/m)
})

test('label order does not split one series into two', () => {
  // 同一组标签换个书写顺序必须是同一条序列 —— 否则一次统计被拆成两半，
  // 而两半加起来才对得上，读的人不会知道。
  const metrics = new Metrics()
  metrics.count('dsh_rpc_requests_total', { op: 'x', result: 'ok' })
  metrics.count('dsh_rpc_requests_total', { result: 'ok', op: 'x' })

  const rows = metrics.render().split('\n').filter((line) => line.startsWith('dsh_rpc_requests_total'))
  assert.deepEqual(rows, ['dsh_rpc_requests_total{op="x",result="ok"} 2'])
})

test('a name that was never declared is not emitted', () => {
  // 拼错一个字母会产出没有 `# TYPE` 的孤儿序列，抓取端会当成另一条指标收下。
  const metrics = new Metrics()
  metrics.count('dsh_rpc_requests_totl', { op: 'x', result: 'ok' })
  assert.equal(metrics.render().includes('dsh_rpc_requests_totl'), false)
})

test('runtime gauges appear only after a sample', () => {
  // 没有采样时报 0 会被读成「内存占用为零」，那比缺一条更坏。
  const empty = new Metrics()
  assert.equal(empty.render().includes('dsh_rss_bytes'), false)

  const withSample = new Metrics()
  withSample.updateRuntime(sample)
  const text = withSample.render()
  assert.match(text, /^dsh_rss_bytes 67633152$/m, '64.5 MB 要换算成字节')
  assert.match(text, /^dsh_ws_clients 3$/m)
  assert.match(text, /^dsh_event_loop_lag_seconds\{quantile="0\.99"\} 0\.021$/m)
})

test('the same state renders byte-for-byte the same', () => {
  // 输出不稳定的话，两次抓取的 diff 里全是噪音。
  const metrics = new Metrics()
  metrics.updateRuntime(sample)
  metrics.count('dsh_rpc_requests_total', { op: 'b', result: 'refused' })
  metrics.count('dsh_rpc_requests_total', { op: 'a', result: 'ok' })
  assert.equal(metrics.render(), metrics.render())
})

// ── 接线：真的请求真的计数 ───────────────────────────────────────────

/** 起一个真监听器。`vault.authenticate` 恒真 —— 这里测的是指标，不是身份。 */
async function withListener(
  run: (base: string, metrics: Metrics) => Promise<void>,
): Promise<void> {
  const metrics = new Metrics()
  const unused = async (): Promise<never> => { throw new Error('not used by this test') }
  const server = createRpcListener({
    sessionPort: { list: async () => [], read: async () => undefined, readAll: async () => undefined },
    limits: DEFAULT_LIMITS,
    vault: { authenticate: () => true } as unknown as CredentialVault,
    writePort: { createSession: unused, promptSession: unused, answerApproval: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: {
      snapshot: () => ({ workspaces: [] }) as never,
      create: unused,
      delete: async () => {},
    },
    permissionPort: undefined,
    auditLog: undefined,
    metrics,
  })

  server.listen(0)
  try {
    await once(server, 'listening')
    const { port } = server.address() as AddressInfo
    await run(`http://127.0.0.1:${port}`, metrics)
  } finally {
    server.closeAllConnections()
    server.close()
  }
}

async function post(base: string, body: unknown): Promise<Response> {
  return fetch(`${base}/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer secret-token' },
    body: JSON.stringify(body),
  })
}

test('GET /metrics answers with the Prometheus content type', async () => {
  await withListener(async (base) => {
    const response = await fetch(`${base}/metrics`)
    assert.equal(response.status, 200)
    assert.match(response.headers.get('content-type') ?? '', /version=0\.0\.4/)
  })
})

test('a request increments the counter', async () => {
  // **这条才是接线判据**：上面那些只证明 `Metrics` 自己会渲染。
  await withListener(async (base, metrics) => {
    await post(base, { v: PROTOCOL_VERSION, op: 'list-sessions' })
    await post(base, { v: PROTOCOL_VERSION, op: 'list-sessions' })

    const rows = metrics.render().split('\n')
      .filter((line) => line.startsWith('dsh_rpc_requests_total'))
    assert.deepEqual(rows, ['dsh_rpc_requests_total{op="list-sessions",result="ok"} 2'])
  })
})

test('a refused request is counted as refused', async () => {
  // 失败率是这三个指标里最有用的一个 —— 它得真的分开记。
  await withListener(async (base, metrics) => {
    await post(base, { v: PROTOCOL_VERSION, op: 'workspace-delete', workspaceId: '' })

    const text = metrics.render()
    assert.match(text, /dsh_rpc_requests_total\{op="workspace-delete",result="refused"\} 1/)
  })
})

test('the metrics page never carries a credential', async () => {
  // 匿名可读的页面：只要有一个字段把请求头带进来，凭据就漏了。
  await withListener(async (base) => {
    await post(base, { v: PROTOCOL_VERSION, op: 'list-sessions' })
    const body = await (await fetch(`${base}/metrics`)).text()

    assert.equal(body.includes('secret-token'), false, '指标页里出现了凭据')
    assert.equal(body.toLowerCase().includes('bearer'), false, '指标页里出现了 Authorization')
  })
})
