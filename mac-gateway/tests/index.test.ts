/**
 * Assembly smoke test. Run: node --test tests/index.test.ts
 *
 * The wiring layer has no pure logic, so it went untested — until a mis-anchored
 * edit shipped a module that evaluated fine and died on the first request. These
 * tests hit a real loopback port: "evaluated" and "wired up" are separate claims.
 *
 * The fake context provides no services: `apply` must still bring the listener up (inject is
 * the host's concern) and answer a protocol message with an envelope — `internal-error` here,
 * since nothing is behind the port — not a crash. M4 adds the auth gate, so the tests pair a
 * seeded device token through the real `refresh` op first; credentials live in a temp directory.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply, inject } from '../src/index.ts'
import { CredentialVault } from '../src/remote/credentials.ts'
import { PROTOCOL_VERSION } from '../src/wire/rpc.ts'

/** Random high port: two tests must not race each other or anything real. */
function freshPort(base: number): number {
  return base + Math.floor(Math.random() * 1_500)
}

/** One temp sandbox per test: a credentials file the real home never sees. */
function tempCredentialsPath(): string {
  return join(mkdtempSync(join(tmpdir(), 'mac-gateway-test-')), 'credentials.json')
}

/** Device token the tests pair with — the raw side of the vault's hash. */
const DEVICE_TOKEN = 'test-device-token-0123456789abcdef'

/** The fake `typertGateway`: a controlled `$events` stream (tests push waterfall frames
 * into it) plus a result door that records what the relay delivered. */
interface FakeGateway {
  push(frame: { type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }): void
  results: { clientId: string; eventId: string; outcome: unknown }[]
}

/**
 * 把伪造的宿主上下文做成**会像真上下文那样拒读**的那一个。
 *
 * cordis 的 get 陷阱对没在 `inject` 里声明的服务属性直接抛
 * （`cannot get property "x" without inject`，reflect.js）。普通对象只会给 `undefined`，
 * 于是「读了没注入的服务」在测试里毫无症状、在真机上让整个插件起不来 ——
 * 命令通道就这样死过一次（`ctx.commands`）。
 *
 * ⚠️ 判据的关键在**不看这个服务在不在**：`services` 里给到它，`ctx.<name>` 照样要拒绝 ——
 * 真实上下文的分界就是 inject 那一名单，与提供者是谁无关。只有 `ctx.reflect.get(name)`
 * 例外（那条路本来就不要求 inject）。
 */
function strictContext(base: Record<string, unknown>, injected: readonly string[]): unknown {
  /** cordis 在任何上下文上都有的成员，以及代理混入的那几个助手方法。 */
  const core = new Set([
    'logger', 'events', 'root', 'fiber', 'scope', 'effect', 'registry',
    'on', 'once', 'off', 'emit', 'parallel', 'serial', 'bail', 'waterfall',
    'plugin', 'inject', 'get', 'provide',
  ])
  return new Proxy(base, {
    get(target, prop, receiver) {
      if (typeof prop === 'symbol') return Reflect.get(target, prop, receiver)
      // 不经 inject 取服务的那条路：仓库里有什么给什么。
      if (prop === 'reflect') return { get: (name: string) => target[name] }
      if (core.has(prop)) return Reflect.get(target, prop, receiver)
      if (injected.includes(prop)) return target[prop]
      throw new Error(`cannot get property "${prop}" without inject`)
    },
  })
}

/**
 * Install the plugin on a context that runs effects immediately; returns its teardown
 * and the fake gateway. `services` adds host services to the fake context (the follow
 * path's three arrive this way), so the default stays the serviceless context the
 * earlier tests depend on.
 */
function install(
  host: string,
  port: number,
  credentialsPath: string,
  services: Record<string, unknown> = {},
  config: Record<string, unknown> = {},
): { teardown: () => void; gateway: FakeGateway } {
  let cleanup: (() => void) | undefined
  const pushes: ((frame: { type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }) => void)[] = []
  const results: { clientId: string; eventId: string; outcome: unknown }[] = []
  const gateway: FakeGateway = {
    results,
    push(frame) {
      for (const push of pushes) push(frame)
    },
  }
  apply(
    strictContext({
      effect: (fn: () => () => void) => { cleanup = fn() },
      /** The in-process Peer source the relay resolves once at assembly (R11) —
       * upstream's `connection.createPeer`, mirrored after
       * `dsh-client-connection/lib/types/rpc-host.d.ts:40-44`. Ahead of `services`
       * so a caller that passes its own `connection` still wins. */
      /** 列表分组的来源。默认空注册表：这组用例问的是列表在投影与缓存异常下的行为，
       * 不是分组结果；要看分组的用例自己传一份。 */
      workspaceRegistry: { list: () => [] },
      connection: {
        createPeer(values: { principal: { kind: string }; interactions?: string }) {
          return {
            principal: values.principal,
            interactions: values.interactions ?? 'answer',
            signal: new AbortController().signal,
          }
        },
      },
      ...services,
      /** Mirrored from the runtime gateway at 0.2.1-alpha.3: `wireStream.open` takes
       * `peer` as a required argument ahead of the signal and reads `peer.signal`
       * before `$events` can open (`dsh-api-gateway/lib/index.js:752,1493`). That is
       * the shape the relay died against while this fixture said `undefined` (R11). */
      typertGateway: {
        wireStream: {
          async open(
            endpoint: string,
            payload: unknown,
            uplink: AsyncIterable<unknown>,
            peer: { signal: AbortSignal },
            signal: AbortSignal,
          ) {
            // The names are upstream's own, so this fixture exercises the
            // named path the wrong way round just as faithfully as the right one.
            void [endpoint, payload, uplink]
            void peer.signal.aborted
            AbortSignal.any([signal, AbortSignal.timeout(60_000)])
            return (async function* () {
              yield { type: 'ready', clientId: 'fake-client' }
              const queue: Array<{ type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }> = []
              pushes.push((frame) => queue.push(frame))
              while (!signal.aborted) {
                while (queue.length > 0) yield queue.shift()!
                await new Promise((resolve) => setTimeout(resolve, 5))
              }
            })()
          },
        },
        // Same treatment as the opener: upstream's own names, and the same
        // `AbortSignal.any` guard, so a misplaced cancellation fails here too.
        async dispatchRpc(
          endpoint: string,
          payload: { args: { clientId: string; eventId: string; outcome: unknown } },
          signal: AbortSignal,
          peer: { signal: AbortSignal },
        ) {
          void endpoint
          // Upstream's answering door reads the Peer first too (`assertPeerLive`).
          void peer.signal.aborted
          AbortSignal.any([signal, AbortSignal.timeout(60_000)])
          results.push(payload.args)
          return { ok: true, value: undefined }
        },
      },
    }, inject) as never,
    { host, port, credentialsPath, deviceTokenSeed: DEVICE_TOKEN, ...config },
  )
  // The credentials file lives exactly as long as the listener does.
  return {
    teardown: () => {
      cleanup?.()
      rmSync(credentialsPath, { force: true })
    },
    gateway,
  }
}

/** Retry the request until the listener is up; give up after two seconds. */
async function untilUp(port: number, request: () => Promise<Response>): Promise<Response> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      return await request()
    } catch {
      await new Promise(resolve => setTimeout(resolve, 50))
    }
  }
  assert.fail('the listener never came up')
}

/** Walk the real auth path: device token → `refresh` op → live access token. */
async function accessTokenFor(port: number): Promise<string> {
  const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ v: 2, op: 'refresh', deviceToken: DEVICE_TOKEN }),
  })
  assert.equal(response.status, 200)
  const body = await response.json() as { ok: boolean; accessToken?: string }
  assert.equal(body.ok, true)
  assert.match(body.accessToken ?? '', /^\S+$/)
  return body.accessToken!
}

/**
 * 打开一条带 access token 的流通道（握手请求里那一个 `authorization` 头，与手机端同款）。
 *
 * 第二参在运行时是 undici 的 init —— `headers` 确实进握手（Node 22 实测），而
 * `@types/node` 只声明协议名 `string | string[]`。类型落后于运行时，故在**这一处**
 * 断言，调用点只表达「要一条带票的流」。
 */
function streamWithToken(port: number, access: string): WebSocket {
  const url = `ws://127.0.0.1:${port}/rpc/stream`
  return new WebSocket(url, { headers: { authorization: `Bearer ${access}` } } as unknown as string[])
}

test('the pair op answers with a full envelope and issues a device token', async () => {
  // 这条路径此前没有判据：`pair` 的四条拒绝理由由 `protocol/auth.test.ts` 覆盖，
  // 而**回包长什么样**只在这里能看到 —— 两条成功应答现在由 `success()` 构造，
  // 少了这条断言，构造方式变了也没人知道。
  const port = freshPort(39_100)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    // 装配时签发的那枚码就在保险库里；重开一个同路径的保险库把它读出来，
    // 而不是去解析控制台输出。
    const code = new CredentialVault(credentialsPath).pairingCode()

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: PROTOCOL_VERSION, op: 'pair', code }),
    })

    assert.equal(response.status, 200)
    const body = await response.json() as { v?: number; ok?: boolean; deviceToken?: string }
    assert.deepEqual({ v: body.v, ok: body.ok }, { v: PROTOCOL_VERSION, ok: true },
      'the success envelope carries the same two fixed fields as a refusal')
    assert.match(body.deviceToken ?? '', /^\S+$/)

    // 同一枚码只能用一次 —— 顺带证明这一条打的是真规则，不是某个假分支。
    const again = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: PROTOCOL_VERSION, op: 'pair', code }),
    })
    assert.equal(again.status, 401)
    const refused = await again.json() as { v?: number; ok?: boolean; error?: { code: string } }
    assert.deepEqual({ v: refused.v, ok: refused.ok, code: refused.error?.code },
      { v: PROTOCOL_VERSION, ok: false, code: 'invalid-pairing-code' })
  } finally {
    teardown()
  }
})

test('the assembled plugin answers a real request on a real port', async () => {
  const port = freshPort(38_100)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    const response = await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    assert.equal(response.status, 200)
    const body = await response.text()
    assert.match(body, /mac-gateway alive/)
    // 版本号取常量作期望值：写死 `v2` 的断言与写死 `v2` 的实现一起过期，
    // 于是那句话可以静默说谎（升到 v3 时报的仍是 2）。
    assert.ok(body.includes(`protocol v${PROTOCOL_VERSION},`),
      `the liveness line must report the running protocol version: ${body.trim()}`)
  } finally {
    teardown()
  }
})

test('a protocol message is answered with an envelope even when nothing is behind the port', async () => {
  const port = freshPort(39_600)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'list-sessions' }),
    })

    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean; error?: { code: string } }
    // The fake context has no services, so the read fails — and must fail as a
    // readable refusal, never as a dead connection.
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
  } finally {
    teardown()
  }
})

// MARK: - the model channel (M7 T3, G4)

/** A fake session controller whose model face is the runtime's, verbatim: `selectModel`
 * answers the *normalized* selection (no sessionId — commands.js:155-160), and
 * `modelCatalog` answers the raw host catalog with `routableProviders` still on it. */
function fakeModelController(): {
  controller: { selectModel: (request: unknown) => Promise<{ selected: unknown }>; modelCatalog: () => Promise<unknown> }
  received: unknown[]
} {
  const received: unknown[] = []
  return {
    received,
    controller: {
      async selectModel(request) {
        received.push(request)
        const { sessionId, ...rest } = request as { sessionId: string; provider: string; model: string }
        void sessionId
        return { selected: rest }
      },
      async modelCatalog() {
        return {
          default: { provider: 'deepseek', model: 'v3.2' },
          groups: [{ id: 'deepseek', name: 'DeepSeek', models: [{ id: 'v3.2', name: 'V3.2' }] }],
          failures: [{ id: 'x', name: 'X', message: 'no credentials' }],
          routableProviders: ['deepseek'],
        }
      },
    },
  }
}

test('model-catalog is answered with the host catalog over real HTTP when the controller is wired', async () => {
  const port = freshPort(42_400)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath, {
    sessionController: fakeModelController().controller,
  })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'model-catalog' }),
    })

    assert.equal(response.status, 200)
    const body = await response.json() as {
      ok: boolean
      default?: { provider: string; model: string }
      groups?: unknown[]
      failures?: unknown[]
      routableProviders?: unknown
    }
    assert.equal(body.ok, true)
    assert.deepEqual(body.default, { provider: 'deepseek', model: 'v3.2' })
    assert.equal(body.groups?.length, 1)
    assert.equal(body.failures?.length, 1)
    // The host-only field must not leak to the phone (决定 7).
    assert.equal('routableProviders' in body, false)
  } finally {
    teardown()
  }
})

test('model-select reaches the controller and answers the normalized selection', async () => {
  const port = freshPort(43_900)
  const credentialsPath = tempCredentialsPath()
  const fake = fakeModelController()
  const { teardown } = install('127.0.0.1', port, credentialsPath, {
    sessionController: fake.controller,
  })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'model-select', sessionId: 's1', provider: 'deepseek', model: 'v3.2' }),
    })

    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean; selected?: unknown }
    assert.equal(body.ok, true)
    // Upstream's answer is the normalized pair — relayed, not re-derived (决定 3).
    assert.deepEqual(body.selected, { provider: 'deepseek', model: 'v3.2' })
    assert.deepEqual(fake.received, [{ sessionId: 's1', provider: 'deepseek', model: 'v3.2' }])
  } finally {
    teardown()
  }
})

test('model ops are answered with an envelope even when no controller is behind the port', async () => {
  const port = freshPort(44_500)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'model-catalog' }),
    })

    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean; error?: { code: string } }
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
  } finally {
    teardown()
  }
})

// MARK: - the command channel (R24 期1: a service the plugin never injected)

/** 宿主命令服务的窄面 —— 形参名照运行时的 `commands/src/index.ts` 写，漂移会被签名检查点出来。 */
function fakeCommands(names: string[]): { service: Record<string, unknown>; executed: string[] } {
  const executed: string[] = []
  return {
    executed,
    service: {
      list(agent: unknown) {
        void agent
        return names.map(name => ({ name, description: `${name} 的说明` }))
      },
      async execute(agent: unknown, line: string, submittedAttachments: readonly never[], signal: AbortSignal) {
        void [agent, submittedAttachments, signal]
        executed.push(line)
        return { commandId: 'cmd-1' }
      },
    },
  }
}

test('the command channel picks up a service it never injected, and reaches it over real HTTP', async () => {
  // `commands` 故意不进 `inject`（它是扩展，缺席不该让整个网关 pending），所以这条
  // 判据盯的是「未经 inject 的那条取数路真的能取到」—— 换成 `ctx.commands` 会抛，
  // 换成装配时取一次就会在这里拿到服务还没就绪的空洞。
  const port = freshPort(45_800)
  const credentialsPath = tempCredentialsPath()
  const commands = fakeCommands(['compact', 'permission'])
  const { teardown } = install('127.0.0.1', port, credentialsPath, {
    commands: commands.service,
    agents: { get: (id: string) => (id === 's1' ? { id } : undefined) },
  })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const send = async (body: Record<string, unknown>): Promise<Record<string, unknown>> => {
      const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
        body: JSON.stringify(body),
      })
      assert.equal(response.status, 200)
      return await response.json() as Record<string, unknown>
    }

    const catalog = await send({ v: 2, op: 'command-catalog', sessionId: 's1' })
    assert.equal(catalog.ok, true, `the lazy resolve must reach the host service: ${JSON.stringify(catalog.error)}`)
    assert.deepEqual((catalog.commands as { name: string }[]).map(row => row.name), ['compact', 'permission'])

    const executed = await send({ v: 2, op: 'command-execute', sessionId: 's1', line: '/permission read-only' })
    assert.equal(executed.ok, true)
    assert.deepEqual(commands.executed, ['/permission read-only'], '整行原样交给宿主，网关不拆参数')
  } finally {
    teardown()
  }
})

test('command ops are refused as an envelope when the command service is absent', async () => {
  const port = freshPort(46_400)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'command-catalog', sessionId: 's1' }),
    })

    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean; error?: { code: string } }
    // 缺席发生在调用时，兑现成同一枚拒绝码 —— 手机不能把「本应拒答」看成死连接。
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
  } finally {
    teardown()
  }
})

// MARK: - the bind address (M8 T2: the exposed surface is withdrawn)

test('the listener binds only to the configured address: another local address is unreachable', { timeout: 10_000 }, async () => {
  const port = freshPort(45_300)
  const credentialsPath = tempCredentialsPath()
  // 127.0.0.1 vs 127.0.0.2: two distinct loopback addresses, so the "reachability
  // surface" claim is observable without a real tailnet (R5's reproducible stand-in —
  // on the Mac the deployment binds 100.64.0.1 and the LAN probe plays 127.0.0.2's part).
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    const up = await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    assert.equal(up.status, 200)

    await assert.rejects(
      fetch(`http://127.0.0.2:${port}/`, { signal: AbortSignal.timeout(3_000) }),
      // 只验「拒了」：`assert.rejects` 没有「不校验错误类型」的签名，给 `Error` 即可
      // —— 握手失败一定落在 Error 家族里，而这一条判据要的是「连不上」这件事本身。
      Error,
      'a device outside the bound address must not even complete a TCP handshake',
    )
  } finally {
    teardown()
  }
})

// MARK: - the auth gate (M4 A4)

test('a business request without credentials is refused as 401 unauthenticated', async () => {
  const port = freshPort(41_000)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: 2, op: 'list-sessions' }),
    })

    assert.equal(response.status, 401)
    const body = await response.json() as { ok: boolean; error?: { code: string } }
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'unauthenticated')
  } finally {
    teardown()
  }
})

test('a bad access token is refused exactly like a missing one', async () => {
  const port = freshPort(41_500)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer not-a-token-we-issued' },
      body: JSON.stringify({ v: 2, op: 'list-sessions' }),
    })

    assert.equal(response.status, 401)
    const body = await response.json() as { error?: { code: string } }
    assert.equal(body.error?.code, 'unauthenticated')
  } finally {
    teardown()
  }
})

test('a wrong device token cannot mint an access token', async () => {
  const port = freshPort(42_000)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))

    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: 2, op: 'refresh', deviceToken: 'not-the-paired-token' }),
    })

    assert.equal(response.status, 401)
    const body = await response.json() as { error?: { code: string } }
    assert.equal(body.error?.code, 'unauthenticated')
  } finally {
    teardown()
  }
})

test('the stream channel answers an upgrade on the same port and refuses a follow as an error frame', { timeout: 10_000 }, async () => {
  const port = freshPort(40_900)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    // A real WebSocket handshake against the assembled listener, with the
    // access token in the upgrade request — the same header the iPhone uses.
    const socket = streamWithToken(port, access)
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('open', () => resolve(), { once: true })
      socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
      setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
    })

    // No session controller behind the port: the pump must fail as an error frame
    // (the stream channel's "a hostile data source is still a reply"), never as a
    // dead socket.
    socket.send(JSON.stringify({ type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } }))
    const reply = await new Promise<Record<string, unknown>>((resolve, reject) => {
      socket.addEventListener('message', event => {
        const frame = JSON.parse(String((event as { data: unknown }).data)) as Record<string, unknown>
        // The relay replays reconciliation + held approvals on every connect;
        // this test only cares about the follow pump's answer.
        if (frame.type === 'approval') return
        resolve(frame)
      })
      socket.addEventListener('error', () => { reject(new Error('socket died instead of answering')) }, { once: true })
      setTimeout(() => { reject(new Error('no frame arrived')) }, 5_000)
    })

    assert.equal(reply.type, 'error')
    assert.equal((reply.payload as { code?: string }).code, 'internal-error')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30)) // let the close clear the heartbeat
  } finally {
    teardown()
  }
})

test('an upgrade without an access token is refused before the handshake', { timeout: 10_000 }, async () => {
  const port = freshPort(42_500)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))

    // No authorization header: the gate must answer 401 at the HTTP layer —
    // the connection never becomes a WebSocket at all.
    await assert.rejects(
      new Promise<void>((resolve, reject) => {
        const socket = new WebSocket(`ws://127.0.0.1:${port}/rpc/stream`)
        socket.addEventListener('open', () => { resolve() }, { once: true })
        socket.addEventListener('error', () => { reject(new Error('upgrade refused')) }, { once: true })
        setTimeout(() => { reject(new Error('upgrade unexpectedly neither opened nor failed')) }, 5_000)
      }),
      /upgrade refused/,
    )
  } finally {
    teardown()
  }
})

// MARK: - the write channel (M5 W5)

test('a real HTTP approval-answer settles a held waterfall frame; the consumed question then refuses', { timeout: 10_000 }, async () => {
  const port = freshPort(43_000)
  const credentialsPath = tempCredentialsPath()
  const { teardown, gateway } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    // The fake host emits one approval waterfall frame; the relay must hold it.
    gateway.push({
      type: 'waterfall',
      event: 'approval/request',
      eventId: 'wire-1',
      agentId: 'agent-1',
      request: { toolName: 'shell', reason: 'needs write' },
    })
    await new Promise((resolve) => setTimeout(resolve, 50))

    const send = async (body: Record<string, unknown>): Promise<{ status: number; body: Record<string, unknown> }> => {
      const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
        body: JSON.stringify(body),
      })
      return { status: response.status, body: await response.json() as Record<string, unknown> }
    }

    const first = await send({ v: 2, op: 'approval-answer', eventId: 'wire-1', decision: 'allow', answerId: 'a1' })
    assert.equal(first.status, 200)
    assert.equal(first.body.ok, true)
    assert.deepEqual(gateway.results, [{
      clientId: 'fake-client',
      eventId: 'wire-1',
      outcome: { kind: 'result', value: 'allowed-once' },
    }], 'the outcome must reach the gateway result door in the upstream vocabulary')

    const consumed = await send({ v: 2, op: 'approval-answer', eventId: 'wire-1', decision: 'deny', answerId: 'a2' })
    assert.equal(consumed.body.ok, false)
    assert.equal((consumed.body.error as { code?: string }).code, 'unknown-approval')
  } finally {
    teardown()
  }
})

test('opening the events stream replays the standing question after ready', { timeout: 10_000 }, async () => {
  const port = freshPort(43_300)
  const credentialsPath = tempCredentialsPath()
  const { teardown, gateway } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    gateway.push({
      type: 'waterfall',
      event: 'approval/request',
      eventId: 'wire-1',
      agentId: 'agent-1',
      request: { toolName: 'shell', reason: 'needs write' },
    })
    await new Promise((resolve) => setTimeout(resolve, 50))

    const socket = streamWithToken(port, access)
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('open', () => resolve(), { once: true })
      socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
      setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
    })

    const items: Array<Record<string, unknown>> = []
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('message', event => {
        const frame = JSON.parse(String((event as { data: unknown }).data)) as { type?: string; payload?: Record<string, unknown> }
        if (frame.type !== 'item' || frame.payload === undefined) return
        items.push(frame.payload)
        if (items.length >= 2) resolve()
      })
      socket.send(JSON.stringify({ type: 'open', streamId: 'ev', payload: { op: 'events' } }))
      setTimeout(() => reject(new Error(`expected ready + waterfall, got ${JSON.stringify(items)}`)), 5_000)
    })

    assert.equal(items[0]?.kind, 'ready', 'the opening item is the source generation, as always')
    assert.equal(items[1]?.kind, 'waterfall',
      'the standing question follows ready — the baseline is the batch of frames itself, not a list')
    assert.equal((items[1] as { agentId?: string }).agentId, 'agent-1',
      'the replay carries the identity too — a live-only field would look right here and fail on reconnect')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})

test('a request that arrives while the events stream is open reaches it live', { timeout: 10_000 }, async () => {
  // 这条与上一条分开：上一条守重放（推送在开流之前），这一条守**实时那一支**的接线。
  // 只守重放的话，`relay.subscribe` 那一行删掉也全绿，而症状是「连着的时候到达的审批
  // 永远不显示，只有重连那一刻才出现」。
  const port = freshPort(43_200)
  const credentialsPath = tempCredentialsPath()
  const { teardown, gateway } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const socket = streamWithToken(port, access)
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('open', () => resolve(), { once: true })
      socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
      setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
    })

    const waterfalls: Array<Record<string, unknown>> = []
    let ready = false
    socket.addEventListener('message', event => {
      const frame = JSON.parse(String((event as { data: unknown }).data)) as { type?: string; payload?: Record<string, unknown> }
      if (frame.type !== 'item') return
      if (frame.payload?.kind === 'ready') { ready = true; return }
      if (frame.payload?.kind === 'waterfall') waterfalls.push(frame.payload)
    })
    socket.send(JSON.stringify({ type: 'open', streamId: 'ev', payload: { op: 'events' } }))
    for (let attempt = 0; attempt < 100 && !ready; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 20))
    }

    // 开流之后才让宿主提出问题 —— 这正是「用户正看着这一屏」的那一刻。
    gateway.push({
      type: 'waterfall',
      event: 'approval/request',
      eventId: 'live-1',
      agentId: 'agent-1',
      request: { toolName: 'shell', reason: 'needs write' },
    })

    for (let attempt = 0; attempt < 100 && waterfalls.length === 0; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    assert.deepEqual(waterfalls, [{
      kind: 'waterfall', event: 'approval/request', eventId: 'live-1',
      agentId: 'agent-1', request: { toolName: 'shell', reason: 'needs write' },
    }], 'a question raised while the stream is open must be pushed, not left until the next reconnect')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})

test('a write op without an access token is refused exactly like a read', { timeout: 10_000 }, async () => {
  const port = freshPort(43_500)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: 2, op: 'session-prompt', sessionId: 's', text: 'hi', promptId: 'p' }),
    })
    assert.equal(response.status, 401)
    const body = await response.json() as { error?: { code?: string } }
    assert.equal(body.error?.code, 'unauthenticated')
  } finally {
    teardown()
  }
})

test('session-prompt without a controller behind the port fails as an envelope, not a crash', { timeout: 10_000 }, async () => {
  const port = freshPort(44_000)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'session-prompt', sessionId: 's', text: 'hi', promptId: 'p' }),
    })
    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean; error?: { code: string } }
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
  } finally {
    teardown()
  }
})

// MARK: - the occupancy frames (M6 U6)

/**
 * A scripted follow stream plus scriptable projections — the two host faces the occupancy path.
 * The opening is whatever the test declares, each `emit` after it one event frame; reads are
 * counted so a test can tell "asked again" from "asked once" — U6's "no news, no frame" half.
 */
function fakeFollowHost(opening: {
  cursor: number
  records: { type: 'event'; event: unknown }[]
  hasMore: boolean
}) {
  const events: unknown[] = []
  let projected: { values: Record<string, unknown>; asOfSeq: number } | undefined
  let reads = 0
  return {
    services: {
      sessions: { get: (id: string) => (id === 's1' ? { id: 's1' } : undefined) },
      sessionProjections: {
        cachedSnapshot: () => undefined,
        snapshot: () => {
          reads += 1
          return projected
        },
      },
      sessionController: {
        follow: async function* (_request: unknown, signal: AbortSignal) {
          yield { type: 'snapshot', ...opening }
          while (!signal.aborted) {
            while (events.length > 0) yield { type: 'event', event: events.shift()! }
            await new Promise(resolve => setTimeout(resolve, 5))
          }
        },
      },
    },
    emit(event: unknown) { events.push(event) },
    project(values: Record<string, unknown> | undefined, asOfSeq: number) {
      projected = values === undefined ? undefined : { values, asOfSeq }
    },
    reads: () => reads,
  }
}

/** Open the stream channel through the real handshake and collect non-approval frames. */
async function openStream(port: number, access: string): Promise<{
  socket: WebSocket
  frames: Record<string, unknown>[]
  waitFor: (predicate: (frames: Record<string, unknown>[]) => boolean, what: string) => Promise<void>
}> {
  const socket = streamWithToken(port, access)
  await new Promise<void>((resolve, reject) => {
    socket.addEventListener('open', () => resolve(), { once: true })
    socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
    setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
  })
  const frames: Record<string, unknown>[] = []
  const waiters: { predicate: (frames: Record<string, unknown>[]) => boolean; resolve: () => void }[] = []
  socket.addEventListener('message', event => {
    const frame = JSON.parse(String((event as { data: unknown }).data)) as Record<string, unknown>
    if (frame.type === 'approval') return // the relay's reconciliation is not this test's subject
    frames.push(frame)
    for (const waiter of [...waiters]) {
      if (!waiter.predicate(frames)) continue
      waiters.splice(waiters.indexOf(waiter), 1)
      waiter.resolve()
    }
  })
  const waitFor = (predicate: (frames: Record<string, unknown>[]) => boolean, what: string): Promise<void> => {
    if (predicate(frames)) return Promise.resolve()
    return new Promise<void>((resolve, reject) => {
      waiters.push({ predicate, resolve })
      setTimeout(() => { reject(new Error(`timed out waiting for ${what}; got ${JSON.stringify(frames)}`)) }, 5_000)
    })
  }
  return { socket, frames, waitFor }
}

/** The opening item frame's payload, once it has arrived (`cursor` marks it). */
function openingOf(frames: Record<string, unknown>[]): Record<string, unknown> | undefined {
  return frames
    .map(frame => frame.payload as Record<string, unknown> | undefined)
    .find(payload => payload !== undefined && payload['cursor'] !== undefined)
}

test('U6: the opening carries an occupancy baseline and a trigger event pushes a frame', { timeout: 15_000 }, async () => {
  const port = freshPort(44_600)
  const credentialsPath = tempCredentialsPath()
  const follow = fakeFollowHost({ cursor: 3, records: [{ type: 'event', event: { type: 'user/message', seq: 2 } }], hasMore: false })
  follow.project({
    contextPressure: { projectedTokens: 52_300, contextWindow: 128_000 },
    contextBreakdown: { systemTokens: 1_000, toolsTokens: 2_000, messageTokens: 49_300 },
  }, 3)
  const { teardown } = install('127.0.0.1', port, credentialsPath, follow.services)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const { socket, frames, waitFor } = await openStream(port, access)

    socket.send(JSON.stringify({ type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } }))
    await waitFor(f => openingOf(f) !== undefined, 'the follow opening')

    // The window and the state travel together, each with its own water mark.
    const opening = openingOf(frames)!
    assert.equal(opening['cursor'], 4, 'the exclusive cursor: the window ends at seq 3')
    assert.deepEqual(opening['occupancy'], {
      asOfSeq: 3,
      usage: {
        usedTokens: 52_300,
        contextWindow: 128_000,
        breakdown: { systemTokens: 1_000, toolsTokens: 2_000, messageTokens: 49_300 },
      },
    })

    // A settling turn moves the projections; the event and the new reading both arrive.
    follow.project({ contextPressure: { projectedTokens: 61_000, contextWindow: 128_000 } }, 5)
    follow.emit({ type: 'assistant/message', seq: 4, data: { usage: { inputTokens: 60_000 } } })
    await waitFor(f => f.some(frame => frame.type === 'usage'), 'the occupancy frame')

    const usageFrame = frames.find(frame => frame.type === 'usage')!
    assert.equal(usageFrame['streamId'], 's1')
    assert.deepEqual(usageFrame['payload'], {
      sessionId: 's1',
      asOfSeq: 5,
      usage: { usedTokens: 61_000, contextWindow: 128_000 },
    })

    // Nothing moved this time: the event still travels, the reading does not.
    follow.emit({ type: 'assistant/message', seq: 5 })
    await waitFor(f => f.some(frame => frame.type === 'item' && (frame.payload as { seq?: number }).seq === 5), 'the second event')
    await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(frames.filter(frame => frame.type === 'usage').length, 1, 'an unchanged value must not earn a second frame')
    assert.ok(follow.reads() >= 3, 'the projections were still read — the frame was skipped, not the read')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})

test('U6: without projections the baseline is absent and no frame is ever pushed', { timeout: 15_000 }, async () => {
  const port = freshPort(44_900)
  const credentialsPath = tempCredentialsPath()
  const follow = fakeFollowHost({ cursor: 1, records: [{ type: 'event', event: { type: 'user/message', seq: 0 } }], hasMore: false })
  follow.project(undefined, 1)
  const { teardown } = install('127.0.0.1', port, credentialsPath, follow.services)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const { socket, frames, waitFor } = await openStream(port, access)

    socket.send(JSON.stringify({ type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } }))
    await waitFor(f => openingOf(f) !== undefined, 'the follow opening')
    assert.equal(openingOf(frames)!['occupancy'], undefined, 'nothing displayable means no baseline, not a zero')

    follow.emit({ type: 'assistant/message', seq: 2 })
    await waitFor(f => f.some(frame => frame.type === 'item' && (frame.payload as { seq?: number }).seq === 2), 'the event')
    await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(frames.filter(frame => frame.type === 'usage').length, 0)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})

// MARK: - the list path against the runtime's projection faces (实施期修正 16)

/**
 * The runtime's cache face as 0.1.7-alpha.2 spells it: `cachedSnapshot(meta, keys)`
 * (dsh-session-projection-cache/lib/index.js:193).
 *
 * The baseline's leading `inheritedEventCount` made a positional `0` mean "no inherited
 * prefix"; the runtime dropped it, so the same `0` now lands in `keys` and upstream's
 * iteration over it throws `number 0 is not iterable` — exactly what killed the real list.
 * This fixture keeps the runtime shape *including the iteration*, because a fixture that
 * ignores its arguments cannot catch that drift.
 */
function fakeProjectionCache(
  valuesFor: (id: string) => Record<string, unknown> | undefined,
): {
  cachedSnapshot: (meta: { id: string }, keys?: readonly string[]) => unknown
  cachedPredecessorTitle: (meta: { id: string }) => unknown
} {
  return {
    cachedSnapshot(meta: { id: string }, keys?: readonly string[]) {
      // The iteration is the drift detector, not decoration.
      for (const key of keys ?? []) void key
      const values = valuesFor(meta.id)
      return values === undefined ? undefined : { asOfSeq: 4, values }
    },
    cachedPredecessorTitle(meta: { id: string }) {
      void meta
      return undefined
    },
  }
}

/** A session row as the corpus yields it: a header plus its liveness. */
function listRecord(id: string, createdAt: number, live: boolean): unknown {
  return { header: { id, createdAt, cwd: '/tmp/project' }, live }
}

test('the list works against the runtime cache face that dropped inheritedEventCount', { timeout: 10_000 }, async () => {
  const port = freshPort(47_000)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath, {
    sessionQuery: {
      listSessions: async () => [
        listRecord('cold-1', 1_700_000_000_000, false),
        listRecord('live-1', 1_700_000_200_000, true),
      ],
    },
    sessions: { get: (id: string) => (id === 'live-1' ? { id } : undefined) },
    sessionProjections: {
      cachedSnapshot: () => ({
        asOfSeq: 9,
        values: { title: '在跑的会话', sessionListMetadata: { lastPromptAt: null, blank: false } },
      }),
      snapshot: () => undefined,
    },
    sessionProjectionCache: fakeProjectionCache(id => ({
      title: `冷却的 ${id}`,
      sessionListMetadata: { lastPromptAt: 1_700_000_100_000, blank: false },
    })),
    agents: { get: (id: string) => (id === 'live-1' ? { status: 'running' } : undefined) },
  })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'list-sessions' }),
    })
    assert.equal(response.status, 200)
    const body = await response.json() as {
      ok: boolean
      error?: { code: string; message: string }
      sessions?: { id: string; title?: string; updatedAt: number; running: boolean }[]
    }
    assert.equal(body.ok, true, `the list must not fail on the cache face: ${JSON.stringify(body.error)}`)
    // Newest first: the live session's `lastPromptAt` is absent, so it falls
    // back to its (later) creation time.
    assert.deepEqual(body.sessions?.map(row => [row.id, row.title, row.running]), [
      ['live-1', '在跑的会话', true],
      ['cold-1', '冷却的 cold-1', false],
    ])
    assert.equal(body.sessions?.[1].updatedAt, 1_700_000_100_000)
  } finally {
    teardown()
  }
})

test('one row whose projection read throws still lists — without its cells', { timeout: 10_000 }, async () => {
  const port = freshPort(48_600)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath, {
    sessionQuery: {
      listSessions: async () => [
        listRecord('fine-1', 1_700_000_300_000, false),
        listRecord('broken-1', 1_700_000_400_000, false),
      ],
    },
    sessions: { get: () => undefined },
    sessionProjections: { cachedSnapshot: () => undefined, snapshot: () => undefined },
    // Mirrors upstream's own `projectionsFor` guard (session-controller/src/list.ts:272–293):
    // a projection is a hint, so one row's failure costs that row its cells, never the list.
    sessionProjectionCache: fakeProjectionCache(id => {
      if (id === 'broken-1') throw new Error('projection column for broken-1 failed')
      return { title: '好的会话', sessionListMetadata: { lastPromptAt: null, blank: false } }
    }),
    agents: { get: () => undefined },
  })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const response = await fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${access}` },
      body: JSON.stringify({ v: 2, op: 'list-sessions' }),
    })
    assert.equal(response.status, 200)
    const body = await response.json() as {
      ok: boolean
      error?: { code: string }
      sessions?: { id: string; title?: string; updatedAt: number }[]
    }
    assert.equal(body.ok, true, `a hint must not fail the list: ${JSON.stringify(body.error)}`)
    assert.deepEqual(body.sessions?.map(row => [row.id, row.title]), [
      ['broken-1', undefined],
      ['fine-1', '好的会话'],
    ])
    // The degraded row keeps its header facts: only the cells are missing.
    assert.equal(body.sessions?.[0].updatedAt, 1_700_000_400_000)
  } finally {
    teardown()
  }
})

// MARK: - the opening size cap (R9 T3: the configured value reaches the adapter)

test('the configured opening cap narrows the window through the real assembly', { timeout: 15_000 }, async () => {
  const port = freshPort(49_200)
  const credentialsPath = tempCredentialsPath()
  // Two turns, each padded past the cap configured below: the assembled adapter must
  // narrow the window to the later turn rather than ship a frame the phone cannot take.
  const big = 'x'.repeat(400)
  const follow = fakeFollowHost({
    cursor: 3,
    records: [
      { type: 'event', event: { type: 'turn/start', seq: 0, time: 1, data: {} } },
      { type: 'event', event: { type: 'user/message', seq: 1, time: 2, data: { text: big } } },
      { type: 'event', event: { type: 'turn/start', seq: 2, time: 3, data: {} } },
      { type: 'event', event: { type: 'user/message', seq: 3, time: 4, data: { text: big } } },
    ],
    hasMore: false,
  })
  const { teardown } = install('127.0.0.1', port, credentialsPath, follow.services, { maxOpeningBytes: 700 })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const { socket, frames, waitFor } = await openStream(port, access)

    socket.send(JSON.stringify({ type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } }))
    await waitFor(f => openingOf(f) !== undefined, 'the follow opening')

    const opening = openingOf(frames)!
    assert.equal(opening['pageStart'], 2, 'the configured cap reached the adapter and narrowed the window')
    assert.equal(opening['hasOlder'], true, 'the narrowed-away part stays reachable')
    assert.equal(opening['cursor'], 4, 'the water mark does not move with the window')
    const wire = Buffer.byteLength(JSON.stringify(frames.find(frame => frame.type === 'item')), 'utf8')
    assert.ok(wire <= 700, `the opening frame fits the configured cap (was ${wire})`)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})
