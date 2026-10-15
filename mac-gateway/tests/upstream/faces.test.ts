/**
 * Tests for the assembly-time shape checks on the approval relay's gateway face
 * (upstream/faces.ts, R11).
 *
 * The relay speaks for a Peer, and on 0.2.1-alpha.3 that Peer is a **required** argument
 * the runtime dereferences (`assertPeerLive` reads `peer.signal.aborted`,
 * `dsh-api-gateway/lib/index.js:1493`). It has to come from `connection.createPeer`
 * (`dsh-client-connection/lib/types/rpc-host.d.ts:40-44`), because an in-process caller
 * has no connection admission to produce one.
 *
 * The fake context mirrors the runtime shapes verbatim — names included — because the
 * point of these checks is that a change *there* is caught *here*, at assembly.
 */

import assert from 'node:assert/strict'
import { mock, test } from 'node:test'
import { gatewayOver, peerShapeProblem } from '../../src/upstream/faces.ts'
import type { PeerScopeLike } from '../../src/upstream/call-through.ts'

/** A Peer as the runtime's `connection.createPeer` returns one. */
function fakePeer(): PeerScopeLike {
  return { principal: { kind: 'owner' }, interactions: 'answer', signal: new AbortController().signal }
}

/**
 * A fake host context. The opener mirrors `dsh-api-gateway/lib/index.js:752` at
 * 0.2.1-alpha.3: the same five parameter names, and the same read of `peer.signal`
 * before `$events` can open.
 */
function fakeContext(options: { peer?: unknown; withoutCreatePeer?: boolean; unreadableOpener?: boolean } = {}) {
  const opens: unknown[] = []
  const answers: unknown[] = []
  const created: unknown[] = []
  const connection = options.withoutCreatePeer === true
    ? {}
    : {
        createPeer(values: unknown) {
          created.push(values)
          return options.peer ?? fakePeer()
        },
      }
  /**
   * `typertGateway` **is** the host instance: the relay resolves it (through
   * `Symbol.for('cordis.original')` when the host wraps it) and calls its members with it as
   * the receiver. The two members do *not* share a shape — `wireStream.open` is an
   * arrow-function **field** (`dsh-api-gateway/lib/index.js:752`), indifferent to how it is
   * called; `dispatchRpc` is a class **method** reading `this.remoteEventClients`
   * (same file, `:967`).
   */
  const ctx = {
    connection,
    typertGateway: {
      remoteEventClients: new Map<string, unknown>(),
      wireStream: {
        open: async (endpoint: unknown, payload: unknown, _uplink: unknown, peer: unknown, signal: unknown) => {
          opens.push(peer)
          void [endpoint, payload]
          void (peer as { signal: AbortSignal }).signal.aborted
          AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(60_000)])
          return (async function* () {})()
        },
      },
      async dispatchRpc(endpoint: unknown, payload: unknown, signal: unknown, peer: unknown) {
        answers.push(peer)
        void [endpoint, payload]
        void this.remoteEventClients.size
        AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(60_000)])
        return { ok: true }
      },
    },
  }
  if (options.unreadableOpener === true) {
    // `bind` is how a service member wrapped by the host looks: no readable names.
    ctx.typertGateway.wireStream.open = ctx.typertGateway.wireStream.open.bind(null)
  }
  return { ctx, opens, answers, created }
}

const SIGNAL = AbortSignal.timeout(60_000)

/** Run `body` with the warn/error channel captured; returns what it received (log.ts: only
 * warn/error go to stderr, info/debug to stdout — so this is exactly the advisory channel). */
async function captureRefusals(body: () => Promise<void> | void): Promise<string[]> {
  const captured: string[] = []
  const spy = mock.method(console, 'error', (...parts: unknown[]) => { captured.push(parts.map(String).join(' ')) })
  try {
    await body()
  } finally {
    spy.mock.restore()
  }
  return captured
}

test('assembly: a complete host assembles without a single warning', async () => {
  // spec 2.2.3「依赖面都齐时，启动不新增告警」—— 这一半此前没有断言（审查发现，R11）。
  const { ctx } = fakeContext()

  const captured = await captureRefusals(async () => {
    const gateway = gatewayOver(ctx as never)
    await gateway.openWireStream('$events', { args: {} }, SIGNAL)
  })

  assert.deepEqual(captured, [], 'a host whose members are all readable must not produce warnings')
})

test('assembly: an unreadable parameter list warns exactly once and still assembles', async () => {
  // 另一半：native 包装不是故障（不得拒绝装配），但必须留下一条 warn —— 按名填已失效、
  // 该成员退到按位置。两半合起来才是 U5。
  const { ctx, opens } = fakeContext({ unreadableOpener: true })

  const captured = await captureRefusals(async () => {
    const gateway = gatewayOver(ctx as never)
    await gateway.openWireStream('$events', { args: {} }, SIGNAL)
  })

  assert.equal(captured.length, 1, 'exactly one warning — the one that says positional fallback is in play')
  assert.match(captured[0]!, /declares/)
  assert.equal(opens.length, 1, 'a warning is not a refusal: the connection still opens')
})

test('assembly: the opener and the answering door speak for one and the same Peer', async () => {
  // No fixed Peer: every `createPeer` call mints a fresh one, so this test fails the
  // moment identity is resolved twice instead of once.
  const { ctx, opens, answers, created } = fakeContext()
  const signal = SIGNAL

  const gateway = gatewayOver(ctx as never)
  await gateway.openWireStream('$events', { args: {} }, signal)
  await gateway.dispatchRpc('$events/result', { args: {} }, signal)

  assert.equal(created.length, 1, 'the Peer is created once, at assembly')
  assert.deepEqual(created[0], { principal: { kind: 'owner' }, interactions: 'answer' })
  assert.notEqual(opens[0], undefined, 'the opener must speak for a Peer, not undefined')
  assert.equal(
    answers[0],
    opens[0],
    'the answering door must speak for the very same object — upstream compares identity by reference',
  )
})

test('assembly: a missing createPeer is a loud failure, not an undefined argument', () => {
  const { ctx } = fakeContext({ withoutCreatePeer: true })

  assert.throws(() => gatewayOver(ctx as never), /createPeer/)
})

test('assembly: a Peer that cannot answer is refused before the first approval arrives', () => {
  const { ctx } = fakeContext({ peer: { principal: { kind: 'owner' }, signal: new AbortController().signal } })

  assert.throws(() => gatewayOver(ctx as never), /interactions=answer/)
})

test('assembly: an unreadable parameter list still gets the Peer, and does not fail assembly', async () => {
  const peer = fakePeer()
  const { ctx, opens } = fakeContext({ peer, unreadableOpener: true })
  const signal = SIGNAL

  const gateway = gatewayOver(ctx as never)
  await gateway.openWireStream('$events', { args: {} }, signal)

  assert.equal(opens[0], peer, 'the arity fallback must still hand the Peer to the opener')
})

test('assembly: the private fallback opener is a method too, and needs its receiver', async () => {
  // With no declared `wireStream`, the face falls back to the private `openWireStream` —
  // a class method that reads `this`, exactly like `dispatchRpc`. A detached call dies.
  const seen: unknown[] = []
  const ctx = {
    connection: { createPeer: () => fakePeer() },
    typertGateway: {
      opens: seen,
      async openWireStream(
        _endpoint: unknown,
        _payload: unknown,
        _uplink: unknown,
        peer: unknown,
        signal: unknown,
      ) {
        this.opens.push(peer)
        AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(60_000)])
        return (async function* () {})()
      },
      async dispatchRpc() { return { ok: true } },
    },
  }

  const gateway = gatewayOver(ctx as never)
  await gateway.openWireStream('$events', { args: {} }, SIGNAL)

  assert.equal(seen.length, 1, 'the fallback opener must run with its receiver, or its `this` reads blow up')
})

test('peerShapeProblem: reports the first field the relay would need and find missing', () => {
  assert.equal(peerShapeProblem(undefined), 'not an object')
  assert.equal(peerShapeProblem({}), 'missing principal')
  assert.equal(peerShapeProblem({ principal: { kind: 'owner' } }), 'missing an AbortSignal signal')
  assert.equal(
    peerShapeProblem({ principal: { kind: 'owner' }, signal: new AbortController().signal }),
    'missing interactions=answer',
  )
  assert.equal(peerShapeProblem(fakePeer()), undefined, 'a Peer as the runtime returns one is usable')
})
