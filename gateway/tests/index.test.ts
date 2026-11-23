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
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { connect as netConnect } from 'node:net'
import { apply, inject } from '../src/index.ts'
import { CredentialVault } from '../src/remote/credentials.ts'
import { setLogSink } from '../src/log.ts'
import { call, callRaw, type UnaryAnswer } from './helpers/http.ts'

/** Random high port: two tests must not race each other or anything real. */
function freshPort(base: number): number {
  return base + Math.floor(Math.random() * 1_500)
}

/** One temp sandbox per test: a credentials file the real home never sees. */
function tempCredentialsPath(): string {
  return join(mkdtempSync(join(tmpdir(), 'dsh-mobile-gateway-test-')), 'credentials.json')
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
      /** 建工作空间的写面。同样只求「在」—— 这组用例不调那条 op。 */
      workspaceController: {
        create: async () => { throw new Error('workspace-create is not exercised here') },
      },
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
  const body = await call(port, 'mobile/refresh', { deviceToken: DEVICE_TOKEN }) as UnaryAnswer & { ok: boolean; accessToken?: string }
  assert.equal(body.status, 200)
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
  const url = `ws://127.0.0.1:${port}/api/remote.mux`
  return new WebSocket(url, { headers: { authorization: `Bearer ${access}` } } as unknown as string[])
}

/**
 * 一次裸 HTTP Upgrade，返回状态行（`101 Switching Protocols` / `409 Conflict` …）。
 *
 * **为什么不用 `WebSocket` 客户端**：它在握手失败时只给一个 `URLError`，
 * 状态码与原因行都读不到 —— 而 409 的判据只能从状态行上看。这条路径发的是一条
 * 合法的升级请求（`Sec-WebSocket-Key` 与版本都对），所以拿到的拒绝是**规则**的，
 * 不是「报文坏了」。
 */
function rawUpgrade(port: number, access: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = netConnect(port, '127.0.0.1', () => {
      socket.write([
        'GET /api/remote.mux HTTP/1.1',
        `Host: 127.0.0.1:${port}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        'Sec-WebSocket-Version: 13',
        `Authorization: Bearer ${access}`,
        '', '',
      ].join('\r\n'))
    })
    let received = ''
    let settled = false
    const finish = (line: string): void => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(line)
    }
    socket.on('data', chunk => {
      received += chunk.toString('utf8')
      const end = received.indexOf('\r\n')
      if (end < 0) return
      finish(received.slice(0, end))
    })
    socket.on('error', (error) => { if (!settled) { settled = true; reject(error) } })
    setTimeout(() => { if (!settled) { settled = true; socket.destroy(); reject(new Error(`no status line; got ${JSON.stringify(received)}`)) } }, 3_000)
  })
}

test('the pair op answers with a full envelope and issues a device token', async () => {
  // 这条路径此前没有判据：`pair` 的四条拒绝理由由 `protocol/auth.test.ts` 覆盖，
  // 而**回包长什么样**只在这里能看到 —— 应答信封由 `wire/unary.ts` 的
  // `encodeServerResponse` 构造，少了这条断言，构造方式变了也没人知道。
  const port = freshPort(39_100)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    // 装配时签发的那枚码就在保险库里；重开一个同路径的保险库把它读出来，
    // 而不是去解析控制台输出。
    const code = new CredentialVault(credentialsPath).pairingCode()

    const body = await call(port, 'mobile/pair', { code }) as UnaryAnswer & { deviceToken?: string }
    assert.equal(body.status, 200)
    assert.equal(body.ok, true)
    // 新信封没有 `v`：版本闸门退役了（见契约 §七）。这一条顺带守住「别把 v 悄悄加回来」。
    assert.equal('v' in body, false, 'the endpoint envelope carries no version field')
    assert.match(body.deviceToken ?? '', /^\S+$/)

    // 同一枚码只能用一次 —— 顺带证明这一条打的是真规则，不是某个假分支。
    const refused = await call(port, 'mobile/pair', { code }) as UnaryAnswer & { error?: { code: string } }
    // 配对失败是**身份断言**，回 401（契约 §4.5）。手机侧据 401 判「这条关系不成立」，
    // 回 200 会让那条分支走不到 —— 撤销之后只会无限重试。
    assert.equal(refused.status, 401)
    assert.equal(refused.ok, false)
    assert.equal(refused.error?.code, 'invalid-pairing-code')
  } finally {
    teardown()
  }
})

test('判据 2：同一身份的第二条 WS 回 409，关掉第一条之后能再连', { timeout: 15_000 }, async () => {
  const port = freshPort(38_600)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    // 第一条走真 WebSocket：它要能 101，也要能收发 —— 只断状态行的话，
    // 一个「回了 101 但没把 socket 交出去」的实现同样全绿。
    const first = streamWithToken(port, access)
    const frames: Record<string, unknown>[] = []
    await new Promise<void>((resolve, reject) => {
      first.addEventListener('open', () => resolve(), { once: true })
      first.addEventListener('error', () => { reject(new Error('the first upgrade failed')) }, { once: true })
      setTimeout(() => { reject(new Error('the first upgrade timed out')) }, 5_000)
    })
    first.addEventListener('message', event => {
      frames.push(JSON.parse(String((event as { data: unknown }).data)) as Record<string, unknown>)
    })
    first.send(JSON.stringify({ type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } }))
    for (let attempt = 0; attempt < 100 && frames.length === 0; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 10))
    }
    assert.equal((frames[0]?.value as Record<string, unknown> | undefined)?.['type'], 'ready',
      '前置：第一条连接真的在用（能开流、能收帧）')

    // 第二条：同一枚 access token → 同一个身份 → 409。
    assert.equal(await rawUpgrade(port, access), 'HTTP/1.1 409 Conflict',
      '一个身份只许一条 socket —— 第二条必须被拒，而且要拒在状态行上')

    // 关掉第一条 → 名额让出来。轮询是因为 release 挂在 socket 的 close 上。
    first.close()
    let status = ''
    for (let attempt = 0; attempt < 100; attempt += 1) {
      status = await rawUpgrade(port, access)
      if (status.startsWith('HTTP/1.1 101')) break
      await new Promise(resolve => setTimeout(resolve, 25))
    }
    assert.equal(status, 'HTTP/1.1 101 Switching Protocols',
      '拒绝之后名额必须真的还回来 —— 否则一次断连就让这台设备永远连不上')
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
    assert.match(body, /dsh-mobile-gateway alive/)
    // 版本号取常量作期望值：写死 `v2` 的断言与写死 `v2` 的实现一起过期，
    // 于是那句话可以静默说谎（升到 v3 时报的仍是 2）。
    // 存活那行要说出协议在哪：`/rpc` 已经不存在了，指向它的句子会让排障的人找错地方。
    assert.ok(body.includes('POST /api/'),
      `the liveness line must name the endpoint path: ${body.trim()}`)
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

    const body = await call(port, 'session/list', { _request: {} }, access) as UnaryAnswer & { ok: boolean; error?: { code: string } }
    assert.equal(body.status, 200)
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

    const body = await call(port, 'session/modelCatalog', {}, access) as UnaryAnswer & {
      ok: boolean
      default?: { provider: string; model: string }
      groups?: unknown[]
      failures?: unknown[]
      routableProviders?: unknown
    }
    assert.equal(body.status, 200)
    assert.equal(body.ok, true)
    assert.deepEqual(body.default, { provider: 'deepseek', model: 'v3.2' })
    assert.equal(body.groups?.length, 1)
    assert.equal(body.failures?.length, 1)
    // 目录是转发的：上游的 `routableProviders` 也在线上形状里（F3 起不再裁）。
    assert.deepEqual(body.routableProviders, ['deepseek'])
    assert.deepEqual(
      Object.keys(body).filter(key => key !== 'status' && key !== 'ok').sort(),
      ['default', 'failures', 'groups', 'routableProviders'],
      '键集合等于上游 `ModelCatalog` —— 少一个就是被裁过',
    )
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

    const body = await call(port, 'session/selectModel', { request: { sessionId: 's1', provider: 'deepseek', model: 'v3.2' } }, access) as UnaryAnswer & { ok: boolean; selected?: unknown }
    assert.equal(body.status, 200)
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

    const body = await call(port, 'session/modelCatalog', {}, access) as UnaryAnswer & { ok: boolean; error?: { code: string } }
    assert.equal(body.status, 200)
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

    const send = async (endpoint: string, args: Record<string, unknown>): Promise<Record<string, unknown>> => {
      const answer = await call(port, endpoint, args, access)
      assert.equal(answer.status, 200)
      return answer
    }

    const catalog = await callRaw(port, 'commands/list', { agentId: 's1' }, access)
    assert.equal(catalog.ok, true, `the lazy resolve must reach the host service: ${JSON.stringify(catalog.error)}`)
    // 裸数组：上游这条回的就是一串描述符。
    assert.deepEqual((catalog.value as { name: string }[]).map(row => row.name), ['compact', 'permission'])

    const executed = await send('commands/execute',
      { agentId: 's1', line: '/permission read-only', submittedAttachments: [] })
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

    const body = await call(port, 'commands/list', { agentId: 's1' }, access) as UnaryAnswer & { ok: boolean; error?: { code: string } }
    assert.equal(body.status, 200)
    // 缺席发生在调用时，兑现成同一枚拒绝码 —— 手机不能把「本应拒答」看成死连接。
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
  } finally {
    teardown()
  }
})

test('the directory browser lists the host file system over real HTTP', async () => {
  // 宿主的 `directoryPickerController` 在 macOS 上只组 `native`（弹系统选择框，只有 `pick`），
  // `list` 根本不存在 —— 所以这一条由网关自己读文件系统。判据因此打的是**真实的一层目录**：
  // 只出子目录、点开头的标 `hidden`、`path` 是绝对路径、面包屑到这一层为止。
  const port = freshPort(46_900)
  const credentialsPath = tempCredentialsPath()
  const root = mkdtempSync(join(tmpdir(), 'dsh-listing-'))
  mkdirSync(join(root, 'beta'))
  mkdirSync(join(root, 'alpha'))
  mkdirSync(join(root, '.hidden'))
  writeFileSync(join(root, 'note.txt'), 'not a directory')
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const listed = await callRaw(port, 'directoryPicker/list', { path: root }, access)
    assert.equal(listed.ok, true, `列目录必须通，实际：${JSON.stringify(listed.error)}`)
    const value = listed.value as {
      path: string; home: string; entries: { name: string; path: string; hidden: boolean }[]
      crumbs: { name: string; path: string }[]; truncated: boolean
    }
    assert.equal(value.path, root, '归一化之后就是请求的那一层')
    assert.equal(value.home, homedir())
    // 文件不在列表里；点开头的在，但标成 hidden；顺序按名字。
    assert.deepEqual(value.entries.map(entry => entry.name), ['.hidden', 'alpha', 'beta'])
    assert.deepEqual(value.entries.map(entry => entry.hidden), [true, false, false])
    assert.deepEqual(value.entries.map(entry => entry.path),
      [join(root, '.hidden'), join(root, 'alpha'), join(root, 'beta')],
      '每一格都是绝对路径 —— 客户端只回声、不拼段')
    assert.equal(value.crumbs.at(-1)?.path, root, '面包屑最后一格就是这一层')
    assert.equal(value.truncated, false)

    // 缺省 = home：不给 path 是合法的一次调用，不是畸形。
    const atHome = await callRaw(port, 'directoryPicker/list', {}, access)
    assert.equal(atHome.ok, true)
    assert.equal((atHome.value as { path: string }).path, homedir())
  } finally {
    teardown()
    rmSync(root, { recursive: true, force: true })
  }
})

test('directoryPicker/list is refused as an envelope when the directory cannot be read', async () => {
  const port = freshPort(47_100)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)

    const body = await call(port, 'directoryPicker/list', { path: '/no-such-directory-here' }, access) as UnaryAnswer & {
      ok: boolean
      error?: { code: string; message?: string }
    }
    assert.equal(body.status, 200)
    // 读不到折成同一枚拒绝码 —— 手机看到的是拒答，不是死连接。
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
    assert.match(body.error?.message ?? '', /ENOENT/, '说法要指到读不到，而不是一句空话')
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

    const body = await call(port, 'session/list', { _request: {} }) as UnaryAnswer & { ok: boolean; error?: { code: string } }
    assert.equal(body.status, 401)
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

    const body = await call(port, 'session/list', { _request: {} }, 'not-a-token-we-issued') as UnaryAnswer & { error?: { code: string } }
    assert.equal(body.status, 401)
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

    const body = await call(port, 'mobile/refresh', { deviceToken: 'not-the-paired-token' }) as UnaryAnswer & { error?: { code: string } }
    // 关系被撤销 = 身份断言，回 401。客户端**正是**靠这个 401 去清凭证、回未配对态；
    // 回 200 的话它会把这条当成传输故障无限重试。
    assert.equal(body.status, 401)
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
    socket.send(JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId: 's1' }, activate: true, assistantStream: true, maxMessages: 500 } } } }))
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
    assert.equal((reply.error as { code?: string }).code, 'internal-error')
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
        const socket = new WebSocket(`ws://127.0.0.1:${port}/api/remote.mux`)
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

/**
 * 开一条 `$events` 流并从 `ready` 里取出 `clientId`。
 *
 * 本期起审批应答必须带它（归属判定的键），而它只从线上来 —— 客户端拿到的是网关在
 * `ready` 里下发的那一个。把它写在一处，是为了让「谁发的 id」在判据里一眼可见。
 */
async function openEventsStream(
  port: number,
  access: string,
): Promise<{ socket: WebSocket; clientId: string; items: Record<string, unknown>[] }> {
  const socket = streamWithToken(port, access)
  await new Promise<void>((resolve, reject) => {
    socket.addEventListener('open', () => resolve(), { once: true })
    socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
    setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
  })
  const items: Record<string, unknown>[] = []
  const clientId = await new Promise<string>((resolve, reject) => {
    socket.addEventListener('message', event => {
      const frame = JSON.parse(String((event as { data: unknown }).data)) as { type?: string; value?: Record<string, unknown> }
      if (frame.type !== 'item' || frame.value === undefined) return
      items.push(frame.value)
      if (frame.value['type'] === 'ready' && typeof frame.value['clientId'] === 'string') {
        resolve(frame.value['clientId'])
      }
    })
    socket.send(JSON.stringify({ type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } }))
    setTimeout(() => { reject(new Error(`no ready frame; got ${JSON.stringify(items)}`)) }, 5_000)
  })
  return { socket, clientId, items }
}

test('判据 7：别人的 clientId 答不了审批，自己的可以；越权留一条 warn', { timeout: 10_000 }, async () => {
  const port = freshPort(43_000)
  const credentialsPath = tempCredentialsPath()
  const { teardown, gateway } = install('127.0.0.1', port, credentialsPath)
  // 留痕是被测的一半（S6 的「可见」）：拒绝只在手机上说一行，归因要回到网关日志。
  const lines: string[] = []
  const previousSink = setLogSink((level, module, line) => { lines.push(`${level}|${module}|${line}`) })

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

    const stream = await openEventsStream(port, access)
    const send = (args: Record<string, unknown>): Promise<UnaryAnswer> =>
      call(port, '$events/result', args, access)
    const answer = (value: string) => ({ kind: 'result', value })

    // ① 一个从未下发过的 clientId：这条流不存在，所以答不了。
    const stranger = await send({ eventId: 'wire-1', outcome: answer('allowed-once'), clientId: 'c-never-issued' })
    assert.equal(stranger.status, 200, '业务拒绝是 200 —— 身份没问题，只是这条审批不是你的')
    assert.equal(stranger.ok, false)
    assert.equal(stranger.error?.code, 'not-owner')
    assert.deepEqual(gateway.results, [], '越权应答一个字节都不该到上游')
    assert.ok(
      lines.some(line => line.startsWith('warn|') && line.includes('c-never-issued')),
      `越权应答要留一条带 clientId 的 warn；实际日志：${lines.join(' / ')}`,
    )

    // ② 自己流上的 clientId：放行，问题被消费。
    const own = await send({ eventId: 'wire-1', outcome: answer('allowed-once'), clientId: stream.clientId })
    assert.equal(own.status, 200)
    assert.equal(own.ok, true)
    assert.deepEqual(gateway.results, [{
      clientId: 'fake-client',
      eventId: 'wire-1',
      outcome: { kind: 'result', value: 'allowed-once' },
    }], 'the outcome must reach the gateway result door in the upstream vocabulary')

    // ③ 同一条再答一次：网关不再判「已经过去了」—— 上游对已结算事件是幂等 no-op，
    //    所以这一发照样放行（第二个到者不会拿到一个与上游相反的结论）。
    const consumed = await send({ eventId: 'wire-1', outcome: answer('rejected'), clientId: stream.clientId })
    assert.equal(consumed.ok, true)
    assert.equal(gateway.results.length, 2, '两次都到了上游，由它决定谁生效')

    stream.socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    setLogSink(previousSink)
    teardown()
  }
})

test('opening the approvals stream replays the standing question after ready', { timeout: 10_000 }, async () => {
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
        const frame = JSON.parse(String((event as { data: unknown }).data)) as { type?: string; value?: Record<string, unknown> }
        if (frame.type !== 'item' || frame.value === undefined) return
        items.push(frame.value)
        if (items.length >= 2) resolve()
      })
      socket.send(JSON.stringify({ type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } }))
      setTimeout(() => reject(new Error(`expected ready + waterfall, got ${JSON.stringify(items)}`)), 5_000)
    })

    assert.equal(items[0]?.type, 'ready', 'the opening item is the source generation, as always')
    assert.equal(items[1]?.type, 'waterfall',
      'the standing question follows ready — the baseline is the batch of frames itself, not a list')
    assert.equal((items[1] as { agentId?: string }).agentId, 'agent-1',
      'the replay carries the identity too — a live-only field would look right here and fail on reconnect')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})

test('a request that arrives while the approvals stream is open reaches it live', { timeout: 10_000 }, async () => {
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
      const frame = JSON.parse(String((event as { data: unknown }).data)) as { type?: string; value?: Record<string, unknown> }
      if (frame.type !== 'item') return
      if (frame.value?.type === 'ready') { ready = true; return }
      if (frame.value?.type === 'waterfall') waterfalls.push(frame.value)
    })
    socket.send(JSON.stringify({ type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } }))
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
      type: 'waterfall', event: 'approval/request', eventId: 'live-1',
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
    const body = await call(port, 'session/prompt', { request: { requestId: 'r', sessionId: 's', mode: 'queue', content: [{ type: 'text', text: 'hi' }] } }) as UnaryAnswer & { error?: { code?: string } }
    assert.equal(body.status, 401)
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
    const body = await call(port, 'session/prompt', { request: { requestId: 'r', sessionId: 's', mode: 'queue', content: [{ type: 'text', text: 'hi' }] } }, access) as UnaryAnswer & { ok: boolean; error?: { code: string } }
    assert.equal(body.status, 200)
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
      sessions: {
        get: (id: string) => (id === 's1' ? { id: 's1' } : undefined),
        list: () => [{ id: 's1' }],
      },
      sessionProjections: {
        cachedSnapshot: () => undefined,
        snapshot: () => {
          reads += 1
          return projected
        },
      },
      sessionController: {
        follow: async function* (_request: unknown, signal: AbortSignal) {
          // 与 control 读的是同一份 `projected`：两条出口必须给出同一个水位下的同一份值。
          yield {
            type: 'snapshot',
            header: { version: 1, id: 's1', createdAt: 1, isSeeded: false },
            ...opening,
            projections: projected ?? { asOfSeq: opening.cursor, values: {} },
          }
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
    .map(frame => frame.value as Record<string, unknown> | undefined)
    .find(payload => payload !== undefined && payload['cursor'] !== undefined)
}

test('U6: control 流给 baseline，触发事件后推一条 projection', { timeout: 15_000 }, async () => {
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

    // 控制流先开：打开时给一份全量（客户端据此建表）。
    socket.send(JSON.stringify({ type: 'open', streamId: 'c1', endpoint: 'session/control', payload: { args: {} } }))
    await waitFor(f => f.some(frame => frame.streamId === 'c1' && frame.type === 'item'), 'the control baseline')
    const baseline = frames.find(frame => frame.streamId === 'c1' && frame.type === 'item')!.value as Record<string, unknown>
    assert.equal(baseline['type'], 'baseline', '第一帧是全量')
    // Host-wide：`value.projections` 是 `{[sessionId]: {asOfSeq, values}}`，与上游同形。
    const blocks = (baseline['value'] as { projections: Record<string, { asOfSeq: number; values: Record<string, unknown> }> }).projections
    assert.equal(blocks['s1']?.asOfSeq, 3, '水位取自投影，不是窗口的 cursor')
    assert.deepEqual(blocks['s1']?.values['contextPressure'],
      { projectedTokens: 52_300, contextWindow: 128_000 }, '整份投影原样带出')

    // 触发源：一条 follow 流，它的事件是「投影可能变了」的信号。
    socket.send(JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId: 's1' }, activate: true, assistantStream: true, maxMessages: 500 } } } }))
    await waitFor(f => f.some(frame => frame.streamId === 's1' && frame.type === 'item'), 'the follow opening')

    // 判据 8：同一 `asOfSeq` 下，两条出口给出同一份视图值。
    const opening = frames.find(frame => frame.streamId === 's1' && frame.type === 'item')!.value as Record<string, unknown>
    assert.deepEqual(opening['projections'], { asOfSeq: 3, values: blocks['s1']?.values },
      '快照的 projections 与 control 的 baseline 必须逐字段相等')

    // 只动 contextPressure：breakdown 原样再给一遍，否则它「消失」也会算一条变更 ——
    // 那是 `project` 的整体替换语义，与本条要守的「只带变了的格」是两件事。
    follow.project({
      contextPressure: { projectedTokens: 61_000, contextWindow: 128_000 },
      contextBreakdown: { systemTokens: 1_000, toolsTokens: 2_000, messageTokens: 49_300 },
    }, 5)
    follow.emit({ type: 'assistant/message', seq: 4, data: { usage: { inputTokens: 60_000 } } })
    await waitFor(f => f.some(frame =>
      frame.streamId === 'c1' && (frame.value as { type?: string } | undefined)?.type === 'projection'), 'the projection patch')

    const patch = frames.find(frame =>
      frame.streamId === 'c1' && (frame.value as { type?: string } | undefined)?.type === 'projection')!.value as Record<string, unknown>
    assert.equal(patch['sessionId'], 's1', '增量指明是谁变了')
    assert.equal(patch['seq'], 4, '引发变化的那个事件的 seq')
    assert.deepEqual(patch['changes'], [
      { key: 'contextPressure', val: { projectedTokens: 61_000, contextWindow: 128_000 } },
    ], '只带变了的格，字段名是 val —— 与上游逐字相同')

    // 没有新事件就不该再有帧：投影没动，读也不必发。
    const before = frames.filter(frame => frame.streamId === 'c1').length
    await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(frames.filter(frame => frame.streamId === 'c1').length, before, '没有触发事件就不重发')

    // 判据 8 的后半：断开 control，follow 的事件照常。两条流互不连坐 —— 这正是
    // 「一条流的事故不拖垮另一条」在 control 与 follow 之间的那一半。
    socket.send(JSON.stringify({ type: 'cancel', streamId: 'c1' }))
    await new Promise(resolve => setTimeout(resolve, 30))
    // seq 必须接着上一条（follow 承诺无缺口，跳号会被泵拒掉）。
    follow.emit({ type: 'assistant/message', seq: 5 })
    await waitFor(f => f.some(frame => frame.streamId === 's1' &&
      (frame.value as { event?: { seq?: number } } | undefined)?.event?.seq === 5),
      'follow still delivers after control closed')

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

    socket.send(JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId: 's1' }, activate: true, assistantStream: true, maxMessages: 500 } } } }))
    await waitFor(f => openingOf(f) !== undefined, 'the follow opening')
    assert.equal(openingOf(frames)!['occupancy'], undefined, 'nothing displayable means no baseline, not a zero')

    follow.emit({ type: 'assistant/message', seq: 2 })
    await waitFor(f => f.some(frame => frame.type === 'item' && (frame.value as { event?: { seq?: number } }).event?.seq === 2), 'the event')
    await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(frames.filter(frame => frame.type === 'usage').length, 0)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
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
  const { teardown } = install('127.0.0.1', port, credentialsPath, follow.services, { maxOpeningBytes: 900 })

  try {
    await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    const access = await accessTokenFor(port)
    const { socket, frames, waitFor } = await openStream(port, access)

    socket.send(JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId: 's1' }, activate: true, assistantStream: true, maxMessages: 500 } } } }))
    await waitFor(f => openingOf(f) !== undefined, 'the follow opening')

    const opening = openingOf(frames)!
    const records = opening['records'] as { event: { seq: number } }[]
    assert.equal(records[0].event.seq, 2, 'the configured cap reached the adapter and narrowed the window')
    assert.equal(opening['hasMore'], true, 'the narrowed-away part stays reachable')
    assert.equal(opening['cursor'], 3, 'the water mark does not move with the window')
    const wire = Buffer.byteLength(JSON.stringify(frames.find(frame => frame.type === 'item')), 'utf8')
    assert.ok(wire <= 900, `the opening frame fits the configured cap (was ${wire})`)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
  }
})
