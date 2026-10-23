/**
 * The approval relay's behaviour: waterfall frames held with their session and announced
 * as changes, one-shot delivery through the result door, and the cancel path.
 *
 * The relay no longer opens `$events` itself, and it no longer builds frames: it subscribes
 * to `ForwardedEvents` (judged on its own in `remote-events.test.ts`) and tells listeners
 * what changed — the frame's shell belongs to the stream pump (`remote/stream.ts`).
 * Here the source is a fake stream and the door is a fake recorder.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ForwardedEvents } from '../../src/upstream/remote-events.ts'
import type { HeldApproval } from '../../src/ports/approval.ts'
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

/** 收集中继的变更 —— 帧的外壳由流泵组，中继只产出数据。 */
function collector() {
  const changes: Array<{ kind: 'waterfall'; held: HeldApproval } | { kind: 'cancel'; eventId: string }> = []
  return {
    changes,
    attach(relay: ApprovalRelay): void {
      relay.onHeld((held) => { changes.push({ kind: 'waterfall', held }) })
      relay.onCancelled((eventId) => { changes.push({ kind: 'cancel', eventId }) })
    },
  }
}

async function liveRelay(options: { refuse?: unknown } = {}) {
  const feed = fakeEventStream()
  const { door, results } = fakeDoor(options)
  const sink = collector()
  const events = new ForwardedEvents(feed.source)
  const relay = new ApprovalRelay(events, door, AbortSignal.timeout(10_000))
  sink.attach(relay)
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

    assert.equal(relay.held()[0]?.agentId, 'session-7',
      'the identity reaches the held set — a frame that only carries it downstream would lose it on replay')
  } finally {
    stop()
  }
})

test('relay: the change says which session the question belongs to, with the upstream fields intact', async () => {
  const { feed, sink, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1', 'shell', 'session-7'))
    await until(() => sink.changes.length === 1, 'the change is announced')
    // 四个字段与上游帧逐字相同：这一层不解释载荷，只搬。
    assert.deepEqual(sink.changes, [{
      kind: 'waterfall',
      held: {
        event: 'approval/request',
        eventId: 'e1',
        agentId: 'session-7',
        request: { toolName: 'shell', reason: 'needs write' },
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
    assert.deepEqual(sink.changes, [], 'and it must not be shown to anyone: a card in the wrong session is worse than no card')
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
    await until(() => sink.changes.length === 2, 'the cancel is announced')

    assert.deepEqual(sink.changes.at(-1), { kind: 'cancel', eventId: 'e1' })
    assert.equal(await relay.answerApproval({ eventId: 'e1', decision: 'allow', answerId: 'k' }), 'unknown-approval')
  } finally {
    stop()
  }
})

test('relay: only approval/request waterfalls are announced — the request body is not interpreted', async () => {
  const { feed, sink, stop } = await liveRelay()
  try {
    feed.push({ type: 'waterfall', event: 'user-questions/request', eventId: 'u1', agentId: 'a', request: { question: 'q' } })
    feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'u2', agentId: 'a', request: {} })
    feed.push({ type: 'emit', event: 'api-session/status', args: [] })
    // 让这三帧走完一整个扇出，再断言 —— 先断言会与上一轮的帧赛跑。
    await new Promise<void>((resolve) => setTimeout(resolve, 50))
    assert.deepEqual(
      sink.changes.map(change => change.kind === 'waterfall' ? change.held.eventId : 'cancel'),
      ['u2'],
      '按事件名筛选：别的 waterfall 与 emit 不进来；而空 request 照收 —— 载荷的内部字段不归中继解释',
    )
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

test('relay: the held set is dropped when the source identity ends', async () => {
  const { feed, relay, events, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1', 'shell', 's1'))
    await until(() => relay.held().length === 1, 'the question is held')
    feed.end()
    await until(() => !events.ready, 'the source is gone')

    // 换代的身份不持有上一代的问题：宿主会把仍在等待的重投给新一代，沿用旧集合就是
    // 重放已消费的投递。客户端那张表的清空由每一条 `ready` 触发（`pumpEvents`）。
    assert.deepEqual(relay.held(), [], 'the previous identity’s questions are not carried over')
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
