/**
 * Assembly smoke test.
 *
 * The wiring layer has no pure logic, which is exactly why it went untested —
 * and a mis-anchored edit once shipped a module that evaluated fine and died on
 * the first request. These tests apply the plugin to a minimal fake context and
 * hit a real loopback port with real HTTP, so "the module evaluated" and "the
 * wiring works" are separate claims, each with a failing state of its own.
 *
 * The fake context deliberately provides no services: `apply` must still bring
 * the listener up (inject is the host's concern), and a protocol message must
 * come back as an envelope — `internal-error` here, since nothing is behind the
 * port — rather than a crash. That is the "the process must not crash" promise,
 * checked at the wiring layer.
 *
 * M4 adds the auth gate: every business request now needs a live access token,
 * so the tests pair a seeded device token through the real `refresh` op first —
 * which also exercises the auth path end to end. The credentials file goes to a
 * temp directory; the tests never touch the real home.
 *
 * Run: node --test src/index.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply } from './index.ts'

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

/**
 * The fake `typertGateway`: a controlled `$events` stream (tests push waterfall
 * frames into it) plus a result door that records what the relay delivered.
 */
interface FakeGateway {
  push(frame: { type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }): void
  results: { clientId: string; eventId: string; outcome: unknown }[]
}

/**
 * Install the plugin on a context that runs effects immediately. Returns its
 * teardown and the fake gateway.
 *
 * `services` adds host services to the fake context — the follow path's three
 * (sessions / sessionProjections / sessionController) arrive this way, so the
 * default stays the serviceless context the earlier tests depend on.
 */
function install(
  host: string,
  port: number,
  credentialsPath: string,
  services: Record<string, unknown> = {},
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
    {
      effect: (fn: () => () => void) => { cleanup = fn() },
      ...services,
      /**
       * Mirrored from the runtime gateway at 0.1.7-alpha.2: the carrier face
       * `wireStream.open` takes `uplink` / `peer` ahead of the signal and
       * combines the signal with a registration lifetime
       * (`dsh-api-gateway/lib/index.js:602,805`). Feeding it positionally is how
       * the relay died on the real machine (实施期修正 15), so the assembly
       * smoke test speaks the same shape.
       */
      typertGateway: {
        wireStream: {
          async open(
            endpoint: string,
            payload: unknown,
            uplink: AsyncIterable<unknown>,
            peer: unknown,
            signal: AbortSignal,
          ) {
            // The names are upstream's own, so this fixture exercises the
            // named path the wrong way round just as faithfully as the right one.
            void [endpoint, payload, uplink, peer]
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
          peer: unknown,
        ) {
          void [endpoint, peer]
          AbortSignal.any([signal, AbortSignal.timeout(60_000)])
          results.push(payload.args)
          return { ok: true, value: undefined }
        },
      },
    } as never,
    { host, port, credentialsPath, deviceTokenSeed: DEVICE_TOKEN },
  )
  return { teardown: () => cleanup?.(), gateway }
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

test('the assembled plugin answers a real request on a real port', async () => {
  const port = freshPort(38_100)
  const credentialsPath = tempCredentialsPath()
  const { teardown } = install('127.0.0.1', port, credentialsPath)

  try {
    const response = await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    assert.equal(response.status, 200)
    assert.match(await response.text(), /mac-gateway alive/)
  } finally {
    teardown()
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
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
    const socket = new WebSocket(`ws://127.0.0.1:${port}/rpc/stream`, { headers: { authorization: `Bearer ${access}` } })
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('open', () => resolve(), { once: true })
      socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
      setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
    })

    // The fake context has no session controller behind the port, so the pump
    // fails — and must fail as an error frame (the stream channel's form of
    // "a hostile data source is still a reply"), never as a dead socket.
    socket.send(JSON.stringify({ type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } }))
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
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
  }
})

// MARK: - the write channel (M5 W5)

/** A waterfall request whose session tail is an `approval/asked` audit event. */
function waterfallRequest(id: string): unknown {
  return {
    agent: {
      session: {
        seq: 1,
        eventAt: (seq: number) => (seq === 0 ? { type: 'approval/asked', data: { id, toolName: 'shell' } } : undefined),
      },
    },
  }
}

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
    rmSync(credentialsPath, { force: true })
  }
})

test('a freshly connected phone is reconciled first: sync frame names the standing ids, then replay', { timeout: 10_000 }, async () => {
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

    const socket = new WebSocket(`ws://127.0.0.1:${port}/rpc/stream`, { headers: { authorization: `Bearer ${access}` } })
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('open', () => resolve(), { once: true })
      socket.addEventListener('error', () => { reject(new Error('upgrade failed')) }, { once: true })
      setTimeout(() => { reject(new Error('upgrade timed out')) }, 5_000)
    })

    const approvalFrames: Array<Record<string, unknown>> = []
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('message', event => {
        const frame = JSON.parse(String((event as { data: unknown }).data)) as { type?: string; payload?: Record<string, unknown> }
        if (frame.type !== 'approval' || frame.payload === undefined) return
        approvalFrames.push(frame.payload)
        if (approvalFrames.length >= 2) resolve()
      })
      setTimeout(() => reject(new Error(`expected sync + request, got ${JSON.stringify(approvalFrames)}`)), 5_000)
    })

    assert.deepEqual(approvalFrames[0], { kind: 'sync', eventIds: ['wire-1'], callIds: [] },
      'the first approval frame must be the reconciliation list, so the client can drop stale cards')
    assert.equal((approvalFrames[1] as { kind?: string }).kind, 'request')
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    teardown()
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
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
    rmSync(credentialsPath, { force: true })
  }
})
