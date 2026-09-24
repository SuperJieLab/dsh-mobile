/**
 * Tests for the by-parameter-name call machinery (upstream/call-through.ts,
 * 实施期修正 15): the opener's parameter *positions* move between upstream builds,
 * names do not. The fake here mirrors the runtime gateway's opener verbatim —
 * signature, `AbortSignal.any` and all — so a positional call breaks end to end.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { callThrough, openStreamThrough, parameterNamesOf } from '../../src/upstream/call-through.ts'

// -- 实施期修正 15: the opener's parameter *positions* move -------------------

/**
 * The runtime gateway's opener, mirrored from dsh-api-gateway/lib/index.js:779 at
 * 0.1.7-alpha.2 — `openWireStream(endpoint, payload, uplink, peer, signal, control)`
 * — with the `AbortSignal.any` its `$events` branch performs (index.js:805). A caller
 * feeding arguments by position breaks here exactly as the phone-side relay did: the
 * signal lands in the uplink slot and cancellation is `undefined`.
 */
function runtimeOpenerLike() {
  const opened: { endpoint: unknown; payload: unknown; uplink: unknown; peer: unknown; signal: unknown; control: unknown }[] = []
  const opener = async (
    endpoint: unknown,
    payload: unknown,
    _uplink: unknown,
    peer: unknown,
    signal: unknown,
    control: unknown,
  ) => {
    opened.push({ endpoint, payload, uplink: _uplink, peer, signal, control })
    // Cancellation is combined with the registration's lifetime, as upstream does.
    const lifetime = AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
    return (async function* () { yield { type: 'ready', clientId: 'upstream' }; if (lifetime.aborted) return })()
  }
  return { opener, opened }
}

test('opener: the signal reaches its own slot in a six-parameter list, not the uplink slot', async () => {
  const { opener, opened } = runtimeOpenerLike()
  const signal = new AbortController().signal

  const stream = await openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, signal })

  assert.equal(opened.length, 1)
  assert.deepEqual(opened[0]!.endpoint, '$events')
  assert.deepEqual(opened[0]!.payload, { args: {} })
  assert.equal(opened[0]!.signal, signal, 'cancellation must reach the parameter named signal')
  assert.equal(opened[0]!.peer, undefined, "undefined is the operator's own in-process carrier")
  assert.equal(opened[0]!.control, undefined, 'an unknown parameter is left to the gateway')
  assert.notEqual(opened[0]!.uplink, signal, 'the uplink slot must not receive the signal')
  const uplink = opened[0]!.uplink as AsyncIterable<unknown>
  assert.equal(typeof uplink[Symbol.asyncIterator], 'function', 'the uplink must be iterable — the gateway releases it on open')

  // The stream is usable, which is the point: the relay iterates what comes back.
  const frames: unknown[] = []
  for await (const frame of stream) frames.push(frame)
  assert.deepEqual(frames, [{ type: 'ready', clientId: 'upstream' }])
})

test('opener: an older three-parameter list still receives the signal', async () => {
  const seen: unknown[] = []
  const opener = async (endpoint: unknown, payload: unknown, signal: unknown) => {
    seen.push(endpoint, payload, signal)
    AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
    return (async function* () { yield { type: 'ready', clientId: 'legacy' } })()
  }
  const signal = new AbortController().signal

  await openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, signal })

  assert.equal(seen[2], signal)
})

test('opener: an unreadable parameter list falls back to arity with cancellation last', async () => {
  const seen: unknown[] = []
  // A bound function exposes `function () { [native code] }`: no names to read.
  const target = async (_endpoint: unknown, _payload: unknown, _uplink: unknown, _peer: unknown, signal: unknown) => {
    seen.push(signal)
    AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
    return (async function* () {})()
  }
  const signal = new AbortController().signal

  await openStreamThrough(target.bind(null), { endpoint: '$events', payload: { args: {} }, signal })

  assert.equal(seen[0], signal)
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

  await openStreamThrough(opener, { endpoint: '$events', payload: { args: {} }, signal })

  assert.deepEqual(seen, ['$events', { args: {} }, seen[2], undefined, signal])
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

test('call: a parameter added ahead of the signal does not displace it', async () => {
  const seen: Record<string, unknown> = {}
  const callee = async (endpoint: unknown, payload: unknown, options: unknown, signal: unknown, peer: unknown) => {
    // What upstream does with the cancellation it was handed.
    AbortSignal.any([signal as AbortSignal, AbortSignal.timeout(10_000)])
    Object.assign(seen, { endpoint, payload, options, signal, peer })
  }
  const signal = new AbortController().signal

  await callThrough(callee, { endpoint: '$events/result', payload: { args: {} }, signal })

  assert.equal(seen.endpoint, '$events/result')
  assert.deepEqual(seen.payload, { args: {} })
  assert.equal(seen.signal, signal, 'the signal must reach the parameter of that name, wherever it moved')
  assert.notEqual(seen.options, signal, 'an argument we cannot supply must not be handed the signal')
})
