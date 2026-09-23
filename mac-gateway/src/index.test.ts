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

// MARK: - the occupancy frames (M6 U6)

/**
 * A scripted follow stream plus scriptable projections — the two host faces the
 * occupancy path reads for real.
 *
 * The opening is whatever the test declares; every `emit` afterwards becomes one
 * event frame. Reads are counted so a test can tell "asked again" from "asked
 * once", which is what the "no news, no frame" half of U6 turns on.
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
  const socket = new WebSocket(`ws://127.0.0.1:${port}/rpc/stream`, { headers: { authorization: `Bearer ${access}` } })
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

    socket.send(JSON.stringify({ type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } }))
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
    assert.equal(usageFrame['streamId'], 1)
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
    rmSync(credentialsPath, { force: true })
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

    socket.send(JSON.stringify({ type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } }))
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
    rmSync(credentialsPath, { force: true })
  }
})

// MARK: - the list path against the runtime's projection faces (实施期修正 16)

/**
 * The runtime's cache face, as 0.1.7-alpha.2 spells it
 * (`dsh-session-projection-cache/lib/index.js:193`):
 *
 * ```js
 * cachedSnapshot(meta, keys) { return this.viewRecord(record, keys) }
 * ```
 *
 * The baseline our code was written against had a leading
 * `inheritedEventCount` — `cachedSnapshot(meta, inheritedEventCount, keys?)` —
 * so a positional `0` used to mean "no inherited prefix". The runtime dropped
 * that parameter, so the same `0` now lands in `keys` and upstream's own
 * iteration over it throws `number 0 is not iterable`, which is exactly what
 * killed the real list. This fixture keeps the runtime shape *including the
 * iteration*: a fixture that ignores its arguments cannot catch that drift.
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
    rmSync(credentialsPath, { force: true })
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
    // Mirrors upstream's own `projectionsFor` guard (session-controller/src/list.ts:
    // 272–293): a projection is a hint, so one row's failure costs that row its
    // cells and never the whole list.
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
    rmSync(credentialsPath, { force: true })
  }
})
