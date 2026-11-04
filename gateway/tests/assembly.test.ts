/**
 * 装配判据：**在真实 cordis 上下文里**加载本插件。
 *
 * 为什么不是又一个假上下文：cordis 对没在 `inject` 里声明的服务属性一读就抛
 * （`cannot get property "x" without inject`），这条规矩属于宿主运行时，手写替身**永远只能
 * 复刻我此刻想到的那一面**。R24 期1 就这样漏过一次：普通对象给 `undefined`，全量测试是绿的，
 * 插件在真机上 `apply` 里当场死掉。所以这一层的判据用真的宿主，不用假件。
 *
 * 两个前提都自己验：`apply` 真的跑了（inject 缺一名就会永远 pending，探针会「通过」得毫无意义），
 * 以及这层上下文真的会拒读（否则下面那条「没崩」什么也证明不了）。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import { apply, inject, name } from '../src/index.ts'

/** 装配时种下的设备令牌；下面用它走真实的鉴权路取一枚访问令牌。 */
const DEVICE_TOKEN = 'assembly-test-device-token-0123456789'

/** 等监听器起来：装配是同步的，但端口就绪要等一拍。 */
async function untilUp(port: number): Promise<void> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      await fetch(`http://127.0.0.1:${port}/`)
      return
    } catch {
      await new Promise(resolve => setTimeout(resolve, 50))
    }
  }
  assert.fail('the listener never came up')
}

/** 设备令牌 → `refresh` → 访问令牌。 */
async function deviceAccess(port: number): Promise<string> {
  await untilUp(port)
  const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ v: 2, op: 'refresh', deviceToken: DEVICE_TOKEN }),
  })
  const body = await response.json() as { ok?: boolean; accessToken?: string }
  assert.equal(body.ok, true)
  return body.accessToken!
}

/** 带票发一次业务请求。 */
async function rpc(port: number, access: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
    body: JSON.stringify({ v: 2, ...body }),
  })
  assert.equal(response.status, 200)
  return await response.json() as Record<string, unknown>
}

/**
 * `inject` 里那几名的最小实现。**缺一名就等于没有判据**：fiber 会停在 pending，
 * `apply` 不跑，测试照样绿（第一版就栽在这上面）。
 */
function hostServices(): Record<string, unknown> {
  return {
    sessionPersistence: {},
    sessionQuery: { listSessions: async () => [] },
    sessionProjections: { cachedSnapshot: () => undefined, snapshot: () => undefined },
    sessionProjectionCache: { cachedSnapshot: () => undefined },
    sessions: { get: () => undefined },
    agents: { get: (id: string) => (id === 's' ? { id } : undefined) },
    // 列表分组用；空注册表就够了 —— 这条用例问的是装配与注入，不是分组结果。
    workspaceRegistry: { list: () => [] },
    // 建工作空间的写面。同样只求「在」。
    workspaceController: { create: async () => { throw new Error('workspace-controller not exercised here') } },
    sessionController: {
      async selectModel(request: unknown) { void request; return { selected: {} } },
      async modelCatalog() { return { groups: [], failures: [] } },
      async follow(request: unknown, signal: AbortSignal) {
        void request
        void signal.aborted
        return (async function* () {})()
      },
    },
    typertGateway: {
      wireStream: {
        async open(endpoint: string, payload: unknown, uplink: AsyncIterable<unknown>, peer: { signal: AbortSignal }, signal: AbortSignal) {
          void [endpoint, payload, uplink, peer.signal, signal]
          return (async function* () {})()
        },
      },
      async dispatchRpc() { return { ok: true } },
    },
    connection: {
      createPeer: () => ({ principal: {}, interactions: 'answer', signal: new AbortController().signal }),
    },
  }
}

test('the plugin starts on a real cordis context and never reads a service it did not inject', async () => {
  const credentialsDir = mkdtempSync(join(tmpdir(), 'dsh-mobile-gateway-assembly-'))
  const credentialsPath = join(credentialsDir, 'credentials.json')
  const port = 34_912
  const root = new Context()
  const services = hostServices()
  for (const [key, value] of Object.entries(services)) root.provide(key, value)

  let started = false
  let guardIsLive = false
  const fiber = root.plugin({
    name,
    inject,
    apply: (ctx: Context) => {
      // 前提一：这层上下文真的会拒读未注入的服务。不成立的话，下面「没崩」毫无意义。
      try {
        void (ctx as unknown as Record<string, unknown>).commands
      } catch (error) {
        guardIsLive = (error as Error).message.includes('without inject')
      }
      apply(ctx as never, {
        host: '127.0.0.1',
        port,
        credentialsPath,
        deviceTokenSeed: DEVICE_TOKEN,
      })
      started = true
    },
  })

  try {
    await fiber
    assert.equal(guardIsLive, true,
      'this context must reject a read of a service it was not injected with — otherwise the test proves nothing')
    assert.equal(started, true, 'apply must actually run: a pending fiber would make this a false green')

    // 命令 op 走一遍：这条路径里才有 `ctx.reflect.get('commands')`。只装着插件不调它，
    // 「reflect 在插件上下文里可读」就仍是我读上游代码猜的，不是验过的。
    //
    // 两个方向都要：缺席 → 拒答（不足为证，`reflect` 本身不可读也会折成同一个码），
    // 补上服务 → 真的列出来。只有正向那一半能证明那条取数路是通的。
    const access = await deviceAccess(port)
    const absent = await rpc(port, access, { op: 'command-catalog', sessionId: 's' })
    assert.equal((absent['error'] as { code?: string } | undefined)?.code, 'internal-error',
      'no command service yet: a refusal, not a dead connection')

    root.provide('commands', {
      list(agent: unknown) {
        void agent
        return [{ name: 'compact', description: 'Compact the conversation' }]
      },
      async execute(agent: unknown, line: string, submittedAttachments: readonly never[], signal: AbortSignal) {
        void [agent, line, submittedAttachments, signal]
        return { commandId: 'cmd-1' }
      },
    })

    // 命令插件晚到（真实启动顺序里就是如此）：下一次调用自己接上，不必重启网关。
    const present = await rpc(port, access, { op: 'command-catalog', sessionId: 's' })
    assert.equal(present['ok'], true,
      `the channel must pick up a service that arrives after assembly: ${JSON.stringify(present['error'])}`)
    assert.deepEqual((present['commands'] as { name: string }[]).map(row => row.name), ['compact'])
  } finally {
    fiber.dispose?.()
    rmSync(credentialsDir, { recursive: true, force: true })
  }
})
