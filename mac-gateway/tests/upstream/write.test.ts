/**
 * The approval relay's behaviour: waterfall frames held and broadcast with their session,
 * one-shot delivery through the result door, the replay sequence, and the cancel path.
 *
 * The relay no longer opens `$events` itself: it subscribes to `ForwardedEvents`
 * (judged on its own in `remote-events.test.ts`). Here the source is a fake stream and
 * the door is a fake recorder — the two things the relay actually talks to.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ForwardedEvents } from '../../src/upstream/remote-events.ts'
import type { UpstreamWireFrame } from '../../src/ports/events.ts'
import {
  ApprovalRelay, ReplayTable, outcomeOfDecision, pumpPrompt, refusalOf,
  type RemoteEventAnswerLike,
} from '../../src/upstream/write.ts'
import { fakeEventStream, until } from './fake-events.ts'

// -- helpers -----------------------------------------------------------------

/** The result door: records every delivery, answers with `refuse` when the test wants it to. */
function fakeDoor(options: { refuse?: unknown } = {}) {
  const results: { clientId: string; eventId: string; outcome: unknown }[] = []
  const door: RemoteEventAnswerLike = {
    async dispatchRpc(_endpoint, payload) {
      const args = (payload as { args: { clientId: string; eventId: string; outcome: unknown } }).args
      results.push(args)
      return options.refuse ?? { ok: true, value: undefined }
    },
  }
  return { door, results }
}

function broadcaster() {
  const frames: unknown[] = []
  return { frames, broadcast(frame: unknown): void { frames.push(frame) } }
}

async function liveRelay(options: { refuse?: unknown } = {}) {
  const feed = fakeEventStream()
  const { door, results } = fakeDoor(options)
  const sink = broadcaster()
  const events = new ForwardedEvents(feed.source)
  const relay = new ApprovalRelay(events, door, sink, AbortSignal.timeout(10_000))
  events.start(AbortSignal.timeout(10_000))
  await feed.started
  await until(() => events.ready, 'the source is ready')
  return { feed, results, sink, events, relay, stop: () => events.stop() }
}

function waterfallFrame(eventId: string, toolName = 'shell', agentId = 'agent-1'): UpstreamWireFrame {
  return { type: 'waterfall', event: 'approval/request', eventId, agentId, request: { toolName, reason: 'needs write' } }
}

/**
 * 截获 warn / error 两级的日志行。
 *
 * 这两级走 `console.error`（`log.ts` 的 `emit` 在**调用时**读它），所以在测试里临时替换
 * 那个函数就能读到它们。替换必须成对（`finally` 里还原），否则后面所有用例的日志都进了
 * 这个数组、别人的断言跟着变。
 */
async function captureLogs(body: () => Promise<void>): Promise<string[]> {
  const lines: string[] = []
  const original = console.error
  console.error = (line: unknown) => { lines.push(String(line)) }
  try {
    await body()
  } finally {
    console.error = original
  }
  return lines
}

// -- 待答与应答 --------------------------------------------------------------

test('relay: the frame says which session the question belongs to, and it is held with it', async () => {
  const { feed, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1', 'shell', 'session-7'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(relay.held()[0]?.sessionId, 'session-7',
      'the identity reaches the held set — a frame that only carries it downstream would lose it on replay')
  } finally {
    stop()
  }
})

test('relay: the broadcast request carries the session too', async () => {
  const { feed, sink, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1', 'shell', 'session-7'))
    await until(() => sink.frames.length === 1, 'the request is broadcast')
    assert.deepEqual(sink.frames, [{
      type: 'approval',
      payload: {
        kind: 'request', eventId: 'e1', sessionId: 'session-7',
        toolName: 'shell', reason: 'needs write',
      },
    }])
  } finally {
    stop()
  }
})

test('relay: a request with no session is neither held nor broadcast, and the log says why', async () => {
  const { feed, sink, relay, stop } = await liveRelay()
  try {
    // 空串与非字符串两种：上游的 agentId 由作用域给出，读不出就是「不知道属于谁」。
    const lines = await captureLogs(async () => {
      feed.push(waterfallFrame('e1', 'shell', ''))
      feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'e2', agentId: 42 as unknown as string, request: { toolName: 'shell' } })
      await new Promise<void>((resolve) => setTimeout(resolve, 80))
    })

    assert.deepEqual(relay.held(), [], 'an unattributable question must not be held — it would be replayed forever')
    assert.deepEqual(sink.frames, [], 'and it must not be shown to anyone: a card in the wrong session is worse than no card')
    assert.ok(lines.some(line => line.includes('no session') && line.includes('e1')),
      `the drop must leave a trace — got ${JSON.stringify(lines)}`)
  } finally {
    stop()
  }
})

test('relay: wire answer reaches the result door with the one-shot outcome; second answer is unknown', async () => {
  const { feed, results, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'deny', answerId: 'k' }), 'delivered')
    assert.deepEqual(results, [{ clientId: 'client-1', eventId: 'e1', outcome: { kind: 'result', value: 'rejected' } }],
      'the answer carries the source’s identity — the relay does not mint one')

    // One-shot: the question is gone; a different answer meets unknown-approval.
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k2' }), 'unknown-approval')
  } finally {
    stop()
  }
})

test('relay: a retried answerId replays the first outcome without a second delivery', async () => {
  const { feed, results, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'deny', answerId: 'same' }), 'delivered')
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'same' }), 'delivered',
      'the first outcome is what a retry must see')
    assert.equal(results.length, 1)
  } finally {
    stop()
  }
})

test('relay: a refused answer is not reported as delivered, and the question stays held', async () => {
  // What the runtime does now (`dsh-api-gateway/lib/index.js:961-977` at 0.2.1-alpha.3):
  // the `$events/result` door validates the Peer, so a mismatch comes back as a value,
  // not a throw. Treating that as "delivered" hides a turn that is still waiting.
  const { feed, results, relay, stop } = await liveRelay({
    refuse: { ok: false, error: { code: 'gateway/interactions-forbidden', message: 'Remote event result belongs to another Peer' } },
  })
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'deny', answerId: 'k' }), 'undelivered')
    assert.equal(results.length, 1, 'the answer still goes out exactly once')
    assert.deepEqual(relay.held().map(held => held.eventId), ['e1'],
      'the question is still open upstream — dropping it here would leave the phone with no way to retry')

    // A second attempt is a second delivery attempt, not a replay of a success.
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k2' }), 'undelivered')
  } finally {
    stop()
  }
})

test('refusalOf: reads the gateway’s encoded failure, and only that', () => {
  assert.equal(refusalOf({ ok: true, value: undefined }), undefined)
  assert.equal(refusalOf({ ok: true }), undefined)
  assert.equal(refusalOf(undefined), undefined, 'a door that hands back nothing is not a refusal')
  assert.equal(
    refusalOf({ ok: false, error: { code: 'gateway/peer-disposed', message: 'the calling Peer has been disposed' } }),
    'gateway/peer-disposed: the calling Peer has been disposed',
  )
  assert.equal(refusalOf({ ok: false }), 'unknown', 'a refusal without a readable code still counts as one')
})

test('relay: a cancel frame clears the question; late answer meets unknown-approval and the phone is told', async () => {
  const { feed, sink, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')
    feed.push({ type: 'cancel', eventId: 'e1' })
    await until(() => sink.frames.length === 2, 'the cancel is broadcast')

    assert.deepEqual(sink.frames.at(-1), { type: 'approval', payload: { kind: 'cancel', eventId: 'e1' } })
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k' }), 'unknown-approval')
  } finally {
    stop()
  }
})

test('relay: non-approval waterfall events, malformed requests and plain emits are ignored', async () => {
  const { feed, sink, stop } = await liveRelay()
  try {
    feed.push({ type: 'waterfall', event: 'user-questions/request', eventId: 'u1', agentId: 'a', request: { question: 'q' } })
    feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'u2', agentId: 'a', request: {} })
    feed.push({ type: 'emit', event: 'api-session/status', args: [] })
    // 让这三帧走完一整个扇出，再断言「什么都没发生」—— 先断言会与上一轮的帧赛跑。
    await new Promise<void>((resolve) => setTimeout(resolve, 50))
    assert.deepEqual(sink.frames, [])
  } finally {
    stop()
  }
})

test('relay: the source dying drops held questions, and the next generation starts clean', async () => {
  // 身份换代 = 宿主会把仍在等待的问题重投一遍。沿用旧集合就是重放已消费的应答，
  // 所以中继必须在「源没了」那一刻把待答表丢掉 —— 这是它跟源一起动的那一半。
  const { feed, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    feed.end()
    await until(() => relay.held().length === 0, 'the held question goes with the source')
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k' }), 'unknown-approval',
      'and an answer that arrives afterwards cannot be delivered to an identity that is gone')
  } finally {
    stop()
  }
})

// -- 连接建立时的重投序列 ----------------------------------------------------

test('relay: the replay puts the ledger first and carries the same identity as the live broadcast', async () => {
  const { feed, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1', 'shell', 's1'))
    // 第二条带 callId：对账名单里的 `callIds` 是客户端判「悬空审计」的唯一依据
    // （日志里有 asked、上游却没有它 —— 重建出来的卡按不动）。不带一条的话，
    // `callIds: []` 与「这个字段根本没算」在断言上完全一样。
    feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'e2', agentId: 's2', request: { toolName: 'write', callId: 'call-1' } })
    await until(() => relay.held().length === 2, 'both questions are held')

    const frames = relay.replayFrames()
    assert.deepEqual(frames.map(frame => frame.payload.kind), ['sync', 'request', 'request'],
      'the ledger comes first — a request that arrives before it would be swept away by the sweep')

    const ledger = frames[0]!.payload
    assert.equal(ledger.kind, 'sync')
    if (ledger.kind !== 'sync') return
    assert.deepEqual(ledger.eventIds, ['e1', 'e2'])
    assert.deepEqual(ledger.callIds, ['call-1'], 'a standing callId must reach the client, or the dangling-audit sweep loses its input')
    assert.equal(ledger.stale, undefined, 'a live source speaks authoritatively — only a dead one says stale')

    const requests = frames.slice(1).map(frame => frame.payload)
    assert.deepEqual(
      requests.map(payload => payload.kind === 'request' ? [payload.eventId, payload.sessionId] : undefined),
      [['e1', 's1'], ['e2', 's2']],
      'the replay must carry the identity: a client that only gets it on the live path loses it after a reconnect',
    )
  } finally {
    stop()
  }
})

test('relay: with no live source the replay is one stale ledger and no requests', async () => {
  const { feed, relay, events, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1', 'shell', 's1'))
    await until(() => relay.held().length === 1, 'the question is held')
    feed.end()
    await until(() => !events.ready, 'the source is gone')

    // 空名单 + stale：客户端据此保留卡片。写成非 stale 的空名单就是一句谎话 ——
    // 它会把这期间别人答掉的卡当成「上游没有」，然后剪掉。
    assert.deepEqual(relay.replayFrames(), [{
      type: 'approval',
      payload: { kind: 'sync', eventIds: [], callIds: [], stale: true },
    }])
  } finally {
    stop()
  }
})

// -- prompt 泵 ---------------------------------------------------------------

test('pump: accepted prompt forwards through the controller door', async () => {
  const seen: unknown[] = []
  const controller = { async prompt(request: unknown) { seen.push(request); return { accepted: true as const } } }
  const outcome = await pumpPrompt(controller, { sessionId: 's', text: 'hi', promptId: 'p' })
  assert.equal(outcome, 'accepted')
  assert.deepEqual(seen, [{ requestId: 'p', sessionId: 's', mode: 'queue', content: [{ type: 'text', text: 'hi' }] }])
})

test('pump: any not-found namespace folds to unknown-session; other failures rethrow', async () => {
  const failing = (thrown: unknown) => ({ async prompt() { throw thrown } })
  const prompt = { sessionId: 's', text: 'hi', promptId: 'p' }
  const remote = (code: string) => Object.assign(new Error(code), { isDSHRemoteError: true, code })

  // The predicate is the shared `/not-found` one, not a hard-coded session code: the
  // namespace belongs to the host, and every call this pump makes is session-addressed.
  assert.equal(await pumpPrompt(failing(remote('session/not-found')), prompt), 'unknown-session')
  assert.equal(await pumpPrompt(failing(remote('agent/not-found')), prompt), 'unknown-session')

  // A remote failure that is not a not-found, and a plain failure, are not the
  // client's to fix by resending.
  await assert.rejects(pumpPrompt(failing(remote('session/busy')), prompt), /session\/busy/)
  await assert.rejects(pumpPrompt(failing(new Error('boom')), prompt), /boom/)
})

// -- 幂等簿记 ---------------------------------------------------------------

test('decision maps onto the one-shot upstream vocabulary only', () => {
  assert.equal(outcomeOfDecision('allow'), 'allowed-once')
  assert.equal(outcomeOfDecision('deny'), 'rejected')
})

test('replay table: first produce runs once, retries replay the first outcome', () => {
  const table = new ReplayTable<string>()
  let runs = 0
  const first = table.remember('k', () => { runs += 1; return 'first' })
  assert.equal(first.fresh, true)
  const retry = table.remember('k', () => { runs += 1; return 'second' })
  assert.equal(retry.fresh, false)
  assert.equal(retry.value, 'first')
  assert.equal(runs, 1)
})
