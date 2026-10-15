/**
 * Tests for the by-parameter-name call machinery (upstream/call-through.ts,
 * 实施期修正 15): the opener's parameter *positions* move between upstream builds,
 * names do not. The fake here mirrors the runtime gateway's opener verbatim —
 * signature, `AbortSignal.any` and all — so a positional call breaks end to end.
 *
 * The opener's shape moved again at 0.2.1-alpha.3 (R11): the `Peer` became a required
 * parameter and the runtime dereferences it before `$events` can open. The fake keeps
 * that dereference, so a caller that hands over `undefined` fails here exactly as the
 * relay did on the real machine.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { callThrough, openStreamThrough, parameterNamesOf, type PeerScopeLike } from '../../src/upstream/call-through.ts'

/** One Peer as the runtime hands it to a stream opener (`PeerScope`). */
function peerScope(): PeerScopeLike {
  return { principal: { kind: 'owner' }, interactions: 'answer', signal: new AbortController().signal }
}

// -- 实施期修正 15 / R11: the opener's parameter *positions* move --------------

/**
 * The runtime gateway's opener, mirrored from dsh-api-gateway/lib/index.js:752 at
 * 0.2.1-alpha.3 — `open(endpoint, payload, uplink, peer, signal)` — with what its
 * `$events` branch does with the Peer: `assertPeerLive` reads `peer.signal.aborted`
 * (index.js:1493) and `openRemoteEvents` folds `peer.signal` into the lifetime
 * (index.js:1000). A caller that hands over `undefined` breaks here first, which is
 * how the relay died on the real machine.
 */
function runtimeOpenerLike() {
  const opened: { endpoint: unknown; payload: unknown; uplink: unknown; peer: unknown; signal: unknown }[] = []
  const opener = async (
    endpoint: unknown,
    payload: unknown,
    _uplink: unknown,
    peer: unknown,
    signal: unknown,
  ) => {
    opened.push({ endpoint, payload, uplink: _uplink, peer, signal })
    // Cancellation is combined with the Peer's lifetime, as upstream does.
    const scope = peer as { signal: AbortSignal }
    const lifetime = AbortSignal.any([signal as AbortSignal, scope.signal, AbortSignal.timeout(10_000)])
    return (async function* () { yield { type: 'ready', clientId: 'upstream' }; if (lifetime.aborted) return })()
  }
  return { opener, opened }
}

test('opener: the signal reaches its own slot in a five-parameter list, not the uplink slot', async () => {
  const { opener, opened } = runtimeOpenerLike()
  const signal = new AbortController().signal
  const peer = peerScope()

  const stream = await openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, peer, signal })

  assert.equal(opened.length, 1)
  assert.deepEqual(opened[0]!.endpoint, '$events')
  assert.deepEqual(opened[0]!.payload, { args: {} })
  assert.equal(opened[0]!.signal, signal, 'cancellation must reach the parameter named signal')
  assert.equal(opened[0]!.peer, peer, 'the Peer must reach the parameter named peer')
  assert.notEqual(opened[0]!.uplink, signal, 'the uplink slot must not receive the signal')
  assert.notEqual(opened[0]!.uplink, peer, 'the uplink slot must not receive the Peer either')
  const uplink = opened[0]!.uplink as AsyncIterable<unknown>
  assert.equal(typeof uplink[Symbol.asyncIterator], 'function', 'the uplink must be iterable — the gateway releases it on open')

  // The stream is usable, which is the point: the relay iterates what comes back.
  const frames: unknown[] = []
  for await (const frame of stream) frames.push(frame)
  assert.deepEqual(frames, [{ type: 'ready', clientId: 'upstream' }])
})

test('opener: a missing Peer fails inside the runtime, which is the failure R11 fixes', async () => {
  const { opener } = runtimeOpenerLike()
  const signal = new AbortController().signal

  // This is the real-machine failure, reproduced verbatim: the fixture dereferences
  // the Peer just as the runtime does, so nothing downstream has to remember it.
  await assert.rejects(
    openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, peer: undefined as unknown as PeerScopeLike, signal }),
    { message: "Cannot read properties of undefined (reading 'signal')" },
  )
})

test('opener: an older three-parameter list still receives the signal', async () => {
  const seen: unknown[] = []
  const opener = async (endpoint: unknown, payload: unknown, signal: unknown) => {
    seen.push(endpoint, payload, signal)
    AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
    return (async function* () { yield { type: 'ready', clientId: 'legacy' } })()
  }
  const signal = new AbortController().signal

  await openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, peer: peerScope(), signal })

  assert.equal(seen[2], signal)
})

test('opener: an unreadable parameter list falls back to arity, Peer and cancellation in their slots', async () => {
  const seen: unknown[] = []
  // A bound function exposes `function () { [native code] }`: no names to read.
  const target = async (_endpoint: unknown, _payload: unknown, _uplink: unknown, peer: unknown, signal: unknown) => {
    seen.push(peer, signal)
    const scope = peer as { signal: AbortSignal }
    AbortSignal.any([signal as AbortSignal, scope.signal, AbortSignal.timeout(10_000)])
    return (async function* () {})()
  }
  const signal = new AbortController().signal
  const peer = peerScope()

  await openStreamThrough(target.bind(null), { endpoint: '$events', payload: { args: {} }, peer, signal })

  assert.equal(seen[0], peer, 'the arity fallback must still put the Peer in the peer slot')
  assert.equal(seen[1], signal)
})

test('opener: renamed parameters fall back to their positional slots', async () => {
  const seen: unknown[] = []
  // What a minified build looks like: names carry no meaning, positions do.
  const opener = async (a: unknown, b: unknown, c: unknown, d: unknown, e: unknown) => {
    seen.push(a, b, c, d, e)
    AbortSignal.any([e as AbortSignal, AbortSignal.timeout(10_000)])
    return (async function* () {})()
  }
  const signal = new AbortController().signal
  const peer = peerScope()

  await openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, peer, signal })

  assert.deepEqual(seen, ['$events', { args: {} }, seen[2], peer, signal])
  assert.equal(typeof (seen[2] as AsyncIterable<unknown>)[Symbol.asyncIterator], 'function')
})

test('opener: a rewritten multi-line parameter list with a trailing comma still reads', () => {
  // Cordis rewrites service members into exactly this shape; the trailing
  // comma yields an empty tail entry that must not pass for a parameter name.
  const rewritten = new Function(
    'return async function open(\n  endpoint,\n  payload,\n  uplink,\n  peer,\n  signal,\n) {}',
  )() as (...args: unknown[]) => unknown
  assert.deepEqual(parameterNamesOf(rewritten), ['endpoint', 'payload', 'uplink', 'peer', 'signal'])
})

test('call: a parameter added ahead of the signal does not displace it, and the Peer still arrives', async () => {
  const seen: Record<string, unknown> = {}
  const callee = async (endpoint: unknown, payload: unknown, options: unknown, signal: unknown, peer: unknown) => {
    // What upstream does with the cancellation it was handed.
    AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
    Object.assign(seen, { endpoint, payload, options, signal, peer })
  }
  const signal = new AbortController().signal
  const peer = peerScope()

  await callThrough(callee, { endpoint: '$events/result', payload: { args: {} }, signal, peer })

  assert.equal(seen.endpoint, '$events/result')
  assert.deepEqual(seen.payload, { args: {} })
  assert.equal(seen.signal, signal, 'the signal must reach the parameter of that name, wherever it moved')
  assert.equal(seen.peer, peer, 'the Peer must reach the parameter of that name too')
  assert.notEqual(seen.options, signal, 'an argument we cannot supply must not be handed the signal')
  assert.notEqual(seen.options, peer, 'an argument we cannot supply must not be handed the Peer')
})

// -- R11, second cut: the host's members are *methods* ------------------------

/**
 * The runtime's `dispatchRpc` is a class method whose body reads a field off `this`
 * (`this.remoteEventClients.get(...)`, dsh-api-gateway/lib/index.js:967). Pulling it out of
 * the instance and calling it as a bare function loses `this`, and the failure is the one the
 * phone hit on the real machine: `Cannot read properties of undefined
 * (reading 'remoteEventClients')`. `wireStream.open` escaped this because it is an arrow
 * function *field* — lexically bound, indifferent to how it is called.
 */
class HostLike {
  readonly remoteEventClients = new Map([['c1', 'the client']])

  async dispatchRpc(endpoint: unknown, payload: unknown, signal: unknown, peer: unknown) {
    void [endpoint, payload, signal, peer]
    return { ok: true, value: this.remoteEventClients.get('c1') }
  }
}

test('call: an unreadable four-parameter answering door still gets its Peer', async () => {
  const seen: unknown[] = []
  // 应答门同样是方法，也可能被包成 native —— 那时按名填失效，只剩 arity 兜底，
  // 而 peer 在最后一槽：兜底漏掉它就等于把「应答进不去」重新演一遍（审查发现，R11）。
  const target = async (_endpoint: unknown, _payload: unknown, signal: unknown, peer: unknown) => {
    seen.push(signal, peer)
    AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
  }
  const signal = new AbortController().signal
  const peer = peerScope()

  await callThrough(target.bind(null), { endpoint: '$events/result', payload: { args: {} }, signal, peer })

  assert.equal(seen[0], signal)
  assert.equal(seen[1], peer, 'the answering door must not lose its Peer when its names are unreadable')
})

test('call: a host method reaches its own state when the receiver comes along', async () => {
  const host = new HostLike()
  const signal = new AbortController().signal

  const reply = await callThrough(
    host.dispatchRpc,
    { endpoint: '$events/result', payload: { args: {} }, signal, peer: peerScope() },
    host,
  )

  assert.deepEqual(reply, { ok: true, value: 'the client' })
})

test('call: without a receiver the host method fails exactly as it did on the real machine', async () => {
  const host = new HostLike()
  const signal = new AbortController().signal

  await assert.rejects(
    callThrough(host.dispatchRpc, { endpoint: '$events/result', payload: { args: {} }, signal, peer: peerScope() }),
    { message: "Cannot read properties of undefined (reading 'remoteEventClients')" },
  )
})
