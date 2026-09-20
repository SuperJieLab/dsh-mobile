/**
 * The approval relay's behaviour tests (M5, 实施期修正 11): waterfall frames
 * held and broadcast, one-shot delivery through the result door, replay, and
 * the cancel path. The gateway is a fake `$events` stream — the same seam the
 * real gateway service presents in-process.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ApprovalRelay, pumpPrompt, type RemoteEventGatewayLike, type UpstreamWireFrame } from './write.ts'

// -- helpers -----------------------------------------------------------------

/** A fake gateway: one controlled `$events` stream plus a recorded result door. */
function fakeGateway() {
  const pushes: ((frame: UpstreamWireFrame) => void)[] = []
  const results: { clientId: string; eventId: string; outcome: unknown }[] = []
  let resolveFirst: (() => void) | undefined
  const streamStarted = new Promise<void>((resolve) => { resolveFirst = resolve })

  const gateway: RemoteEventGatewayLike & { push(frame: UpstreamWireFrame): void } = {
    async *openWireStream(endpoint, _payload, signal) {
      assert.equal(endpoint, '$events')
      const queue: UpstreamWireFrame[] = []
      // Register the push channel BEFORE the first yield: a frame pushed
      // between body start and the ready frame must not be lost.
      pushes.push((frame) => queue.push(frame))
      resolveFirst?.()
      yield { type: 'ready', clientId: 'fake-client' }
      while (!signal.aborted) {
        while (queue.length > 0) yield queue.shift()!
        await new Promise<void>((r) => setTimeout(r, 5))
      }
    },
    async dispatchRpc(_endpoint, payload) {
      const args = (payload as { args: { clientId: string; eventId: string; outcome: unknown } }).args
      results.push(args)
      return { ok: true, value: undefined }
    },
    push(frame) {
      for (const push of pushes) push(frame)
    },
  }
  return { gateway, results, streamStarted }
}

function broadcaster() {
  const frames: unknown[] = []
  return { frames, broadcast(frame: unknown): void { frames.push(frame) } }
}

async function liveRelay() {
  const { gateway, results, streamStarted } = fakeGateway()
  const sink = broadcaster()
  const relay = new ApprovalRelay(gateway, sink)
  relay.start(AbortSignal.timeout(10_000))
  await streamStarted
  return { gateway, results, sink, relay, stop: () => relay.stop() }
}

function waterfallFrame(eventId: string, toolName = 'shell'): UpstreamWireFrame {
  return { type: 'waterfall', event: 'approval/request', eventId, agentId: 'agent-1', request: { toolName, reason: 'needs write' } }
}

test('relay: a waterfall frame is held and broadcast; the phone sees the request payload', async () => {
  const { gateway, sink, stop } = await liveRelay()
  try {
    gateway.push(waterfallFrame('e1'))
    await new Promise((r) => setTimeout(r, 30))
    assert.deepEqual(sink.frames, [{
      type: 'approval',
      payload: { kind: 'request', eventId: 'e1', toolName: 'shell', reason: 'needs write' },
    }])
  } finally {
    stop()
  }
})

test('relay: wire answer reaches the result door with the one-shot outcome; second answer is unknown', async () => {
  const { gateway, results, relay, stop } = await liveRelay()
  try {
    gateway.push(waterfallFrame('e1'))
    await new Promise((r) => setTimeout(r, 30))

    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'deny', answerId: 'k' }), 'delivered')
    assert.deepEqual(results, [{ clientId: 'fake-client', eventId: 'e1', outcome: { kind: 'result', value: 'rejected' } }])

    // One-shot: the question is gone; a different answer meets unknown-approval.
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k2' }), 'unknown-approval')
  } finally {
    stop()
  }
})

test('relay: a retried answerId replays the first outcome without a second delivery', async () => {
  const { gateway, results, relay, stop } = await liveRelay()
  try {
    gateway.push(waterfallFrame('e1'))
    await new Promise((r) => setTimeout(r, 30))

    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'deny', answerId: 'same' }), 'delivered')
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'same' }), 'delivered',
      'the first outcome is what a retry must see')
    assert.equal(results.length, 1)
  } finally {
    stop()
  }
})

test('relay: a cancel frame clears the question; late answer meets unknown-approval and the phone is told', async () => {
  const { gateway, sink, relay, stop } = await liveRelay()
  try {
    gateway.push(waterfallFrame('e1'))
    await new Promise((r) => setTimeout(r, 30))
    gateway.push({ type: 'cancel', eventId: 'e1' })
    await new Promise((r) => setTimeout(r, 30))

    assert.deepEqual(sink.frames.at(-1), { type: 'approval', payload: { kind: 'cancel', eventId: 'e1' } })
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k' }), 'unknown-approval')
  } finally {
    stop()
  }
})

test('relay: non-approval waterfall events and malformed requests are ignored', async () => {
  const { gateway, sink, stop } = await liveRelay()
  try {
    gateway.push({ type: 'waterfall', event: 'user-questions/request', eventId: 'u1', agentId: 'a', request: { question: 'q' } })
    gateway.push({ type: 'waterfall', event: 'approval/request', eventId: 'u2', agentId: 'a', request: {} })
    gateway.push({ type: 'emit', event: 'api-session/status', args: {} })
    await new Promise((r) => setTimeout(r, 30))
    assert.deepEqual(sink.frames, [])
  } finally {
    stop()
  }
})

test('relay: a broken stream reconnects and the next generation serves fresh frames', async () => {
  let attempts = 0
  const sink = broadcaster()
  const results: unknown[] = []
  const relay = new ApprovalRelay({
    // First generation dies instantly (the old relay would stay dead until
    // the next plugin reload — exactly the failure the phone experienced as
    // "approval cards vanish"); the second serves normally.
    async * openWireStream(_endpoint, _payload, signal) {
      attempts += 1
      if (attempts === 1) throw new Error('stream broke')
      yield { type: 'ready', clientId: 'fake-client-2' }
      while (!signal.aborted) await new Promise((r) => setTimeout(r, 5))
    },
    async dispatchRpc(_endpoint, payload) {
      results.push((payload as { args: unknown }).args)
      return { ok: true }
    },
  }, sink)
  relay.start(AbortSignal.timeout(10_000))
  try {
    // 500 ms initial backoff; wait past it plus slack.
    await new Promise((r) => setTimeout(r, 900))
    assert.equal(attempts >= 2, true, 'the relay must attempt a second generation')
    assert.equal(relay.ready, true, 'the relay must be live again after reconnect')
  } finally {
    relay.stop()
  }
})

// -- prompt pump (unchanged by 修正 11) ---------------------------------------

test('pump: accepted prompt forwards through the controller door', async () => {
  const seen: unknown[] = []
  const controller = { async prompt(request: unknown) { seen.push(request); return { accepted: true as const } } }
  const outcome = await pumpPrompt(controller, { sessionId: 's', text: 'hi', promptId: 'p' })
  assert.equal(outcome, 'accepted')
  assert.deepEqual(seen, [{ requestId: 'p', sessionId: 's', mode: 'queue', content: [{ type: 'text', text: 'hi' }] }])
})

test('pump: not-found folds to unknown-session; other failures rethrow', async () => {
  const controller = { async prompt() { throw Object.assign(new Error('gone'), { isDSHRemoteError: true, code: 'session/not-found' }) } }
  assert.equal(await pumpPrompt(controller, { sessionId: 's', text: 'hi', promptId: 'p' }), 'unknown-session')

  const broken = { async prompt() { throw new Error('boom') } }
  await assert.rejects(pumpPrompt(broken, { sessionId: 's', text: 'hi', promptId: 'p' }), /boom/)
})
