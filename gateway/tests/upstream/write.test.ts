/**
 * The approval relay's behaviour: waterfall frames held with their session and announced
 * as changes, one-shot delivery through the result door, and the cancel path.
 *
 * The relay no longer opens `$events` itself, and it no longer builds frames: it subscribes
 * to `ForwardedEvents` (judged on its own in `remote-events.test.ts`) and tells listeners
 * what changed — the frame's shell belongs to the stream pump (`remote/stream.ts`).
 * Here the source is a fake stream and the door is a fake recorder.
 *
 * 第 3 期之后中继**不再解释应答**：`outcome` 由客户端给出，原样转发；「还在不在」
 * 由上游判（对已结算事件是幂等 no-op），本地那张重放表与词汇映射都删了。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ForwardedEvents } from '../../src/upstream/remote-events.ts'
import type { HeldApproval } from '../../src/ports/approval.ts'
import type { UpstreamWireFrame } from '../../src/ports/events.ts'
import type { RemoteEventResultMessage } from '../../src/wire/write.ts'
import {
  ApprovalRelay, pumpPrompt, refusalOf,
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
  const changes: Array<{ type: 'waterfall'; held: HeldApproval } | { type: 'cancel'; eventId: string }> = []
  return {
    changes,
    attach(relay: ApprovalRelay): void {
      relay.onHeld((held) => { changes.push({ type: 'waterfall', held }) })
      relay.onCancelled((eventId) => { changes.push({ type: 'cancel', eventId }) })
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

/** 一条审批应答 —— 三键，没有 `answerId`。  // terms-ok: 说明已退场的键 */
function approvalAnswer(eventId: string, value: 'allowed-once' | 'rejected'): RemoteEventResultMessage {
  return { clientId: 'c-test', eventId, outcome: { kind: 'result', value } }
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
      type: 'waterfall',
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

test('relay: 应答的 outcome 原样到达结果门，身份换成网关自己的那一个', async () => {
  const { feed, results, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerEvent(approvalAnswer('e1', 'rejected')), 'delivered')
    assert.deepEqual(results, [{ clientId: 'client-1', eventId: 'e1', outcome: { kind: 'result', value: 'rejected' } }],
      '网关不翻译词汇、不铸身份 —— 它只把手机那条换成自己的上游身份')

    // 本地暂存项跟着这次结算走：不等 cancel 帧。
    assert.deepEqual(relay.held(), [], 'answered questions do not wait for the cancel frame to leave the replay set')
  } finally {
    stop()
  }
})

test('relay: 同一条再答一次照样投出去 —— 由上游判 no-op，网关不判「还在不在」', async () => {
  const { feed, results, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerEvent(approvalAnswer('e1', 'rejected')), 'delivered')
    assert.equal(await relay.answerEvent(approvalAnswer('e1', 'allowed-once')), 'delivered',
      '上游对已结算事件是幂等 no-op，不是错误')
    assert.equal(results.length, 2, '两次都真的发出去了 —— 本地替上游下结论就是第二份判据')
  } finally {
    stop()
  }
})

test('relay: 问题答案整批原样转发，网关不再读卡上问了几问', async () => {
  const { feed, relay, results, stop } = await liveRelay()
  try {
    feed.push({
      type: 'waterfall', event: 'user-questions/request', eventId: 'q1', agentId: 'agent-1',
      request: { questions: [{ id: 'q-1' }, { id: 'q-2' }] },
    })
    await until(() => relay.held().length === 1, '问题被收下')

    const outcome = await relay.answerEvent({
      clientId: 'c-test', eventId: 'q1',
      // 少一项也照转：完整性的判定在客户端提交前，不在这里。
      outcome: { kind: 'result', value: { answers: [{ id: 'q-1', selected: ['A'] }] } },
    })

    assert.equal(outcome, 'delivered')
    assert.deepEqual(results[0]?.outcome,
      { kind: 'result', value: { answers: [{ id: 'q-1', selected: ['A'] }] } })
  } finally {
    stop()
  }
})

test('relay: next 不给其它投递方结算，所以它不删本地暂存项', async () => {
  const { feed, relay, results, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerEvent({ clientId: 'c-test', eventId: 'e1', outcome: { kind: 'next' } }), 'delivered')
    assert.equal(results.length, 1)
    assert.deepEqual(relay.held().map(held => held.eventId), ['e1'],
      '还有别的投递方没答，这一条不该从重放集合里消失')
  } finally {
    stop()
  }
})

test('relay: a refused answer is not reported as delivered, and the question stays held', async () => {
  // What the runtime does (`dsh-api-gateway/lib/index.js:961-977` at 0.2.1-alpha.3):
  // the `$events/result` door validates the Peer, so a mismatch comes back as a value,
  // not a throw. Treating that as "delivered" hides a turn that is still waiting.
  const { feed, results, relay, stop } = await liveRelay({
    refuse: { ok: false, error: { code: 'gateway/interactions-forbidden', message: 'Remote event result belongs to another Peer' } },
  })
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    assert.equal(await relay.answerEvent(approvalAnswer('e1', 'rejected')), 'undelivered')
    assert.equal(results.length, 1, 'the answer still goes out exactly once')
    assert.deepEqual(relay.held().map(held => held.eventId), ['e1'],
      'the question is still open upstream — dropping it here would leave the phone with no way to retry')
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

test('relay: a cancel frame clears the question; a late answer still goes out and upstream no-ops it', async () => {
  const { feed, sink, results, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')
    feed.push({ type: 'cancel', eventId: 'e1' })
    await until(() => sink.changes.length === 2, 'the cancel is announced')

    assert.deepEqual(sink.changes.at(-1), { type: 'cancel', eventId: 'e1' })
    assert.equal(await relay.answerEvent(approvalAnswer('e1', 'allowed-once')), 'delivered',
      '迟到的应答照发：上游知道这条已经结算，回一个 no-op')
    assert.equal(results.length, 1)
  } finally {
    stop()
  }
})

test('relay: 第二类挂起项也被收下 —— 上游提问不再静默消失', async () => {
  const { feed, sink, relay, stop } = await liveRelay()
  try {
    feed.push({
      type: 'waterfall', event: 'user-questions/request', eventId: 'q1', agentId: 'agent-1',
      request: { questions: [{ id: 'q-1', question: '用哪条？' }] },
    })
    await until(() => relay.held().length === 1, '问题被收下')
    assert.equal(sink.changes.length, 1, '它还要被通知一次 —— 否则 ready 之后的重放里没有它')
    assert.equal(relay.held()[0].event, 'user-questions/request', '类别由 event 那一格带着')
  } finally {
    stop()
  }
})

test('relay: 两类混排时按到达顺序留在表里 —— 重放的顺序就是到达的顺序', async () => {
  const { feed, relay, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('a1'))
    feed.push({ type: 'waterfall', event: 'user-questions/request', eventId: 'q1', agentId: 'agent-1', request: { questions: [] } })
    feed.push(waterfallFrame('a2'))
    await until(() => relay.held().length === 3, '三条都收下')

    assert.deepEqual(relay.held().map(item => item.eventId), ['a1', 'q1', 'a2'],
      '两类进同一张表，顺序即到达顺序 —— 分两张表就没有这个顺序可言')
  } finally {
    stop()
  }
})

test('relay: 不认得的 waterfall 类别不进表，但留一条带事件名的痕', async () => {
  const { feed, relay, sink, stop } = await liveRelay()
  try {
    const lines = await captureLogs(async () => {
      feed.push({ type: 'waterfall', event: 'third/thing', eventId: 'x1', agentId: 'a', request: {} })
      await new Promise<void>((resolve) => setTimeout(resolve, 80))
    })

    assert.deepEqual(relay.held(), [], '没有定义过「该怎么存」的类别不猜')
    assert.deepEqual(sink.changes, [], '也不通知任何人')
    assert.ok(lines.some(line => line.includes('unseen kind') && line.includes('third/thing')),
      `丢弃必须留痕，且带事件名 —— 否则「上游加了新挂起项」在日志里看不出来。实际：${JSON.stringify(lines)}`)
  } finally {
    stop()
  }
})

test('relay: 两类待答调用都进表，其余 waterfall 与 emit 不进 —— 载荷内部不归中继解释', async () => {
  const { feed, sink, stop } = await liveRelay()
  try {
    feed.push({ type: 'waterfall', event: 'user-questions/request', eventId: 'u1', agentId: 'a', request: { question: 'q' } })
    feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'u2', agentId: 'a', request: {} })
    feed.push({ type: 'waterfall', event: 'third/thing', eventId: 'u3', agentId: 'a', request: {} })
    feed.push({ type: 'emit', event: 'api-session/status', args: [] })
    // 让这几帧走完一整个扇出，再断言 —— 先断言会与上一轮的帧赛跑。
    await new Promise<void>((resolve) => setTimeout(resolve, 50))
    assert.deepEqual(
      sink.changes.map(change => change.type === 'waterfall' ? change.held.eventId : 'cancel'),
      ['u1', 'u2'],
      '两类都收、按到达顺序；第三种 waterfall 与 emit 不进来；空 request 照收 —— 载荷的内部字段不归中继解释',
    )
  } finally {
    stop()
  }
})

test('relay: the source dying drops held questions, and the next generation starts clean', async () => {
  // 身份换代 = 宿主会把仍在等待的问题重投一遍。沿用旧集合就是重放已消费的应答，
  // 所以中继必须在「源没了」那一刻把待答表丢掉 —— 这是它跟源一起动的那一半。
  // 客户端那张表的清空由每一条 `ready` 触发（`pumpApprovals`），不在这里。
  const { feed, relay, events, stop } = await liveRelay()
  try {
    feed.push(waterfallFrame('e1'))
    await until(() => relay.held().length === 1, 'the question is held')

    feed.end()
    await until(() => !events.ready, 'the source is gone')
    assert.deepEqual(relay.held(), [], 'the previous identity’s questions are not carried over')
    assert.equal(await relay.answerEvent(approvalAnswer('e1', 'allowed-once')), 'undelivered',
      'and an answer that arrives afterwards cannot be delivered to an identity that is gone')
  } finally {
    stop()
  }
})

// -- prompt 泵 ---------------------------------------------------------------

test('pump: the five fields go through the controller door verbatim', async () => {
  const seen: unknown[] = []
  const controller = { async prompt(request: unknown) { seen.push(request); return { accepted: true as const } } }
  const outcome = await pumpPrompt(controller, {
    requestId: 'r-1',
    sessionId: 's',
    mode: 'steer',
    content: [{ type: 'text', text: 'hi' }, { type: 'text', text: 'again' }],
    clientTimeZone: 'Asia/Shanghai',
  })
  assert.equal(outcome, 'accepted')
  assert.deepEqual(seen, [{
    requestId: 'r-1',
    sessionId: 's',
    mode: 'steer',
    content: [{ type: 'text', text: 'hi' }, { type: 'text', text: 'again' }],
    clientTimeZone: 'Asia/Shanghai',
  }], '网关不拼内容、不固定 queue、不丢时区')
})

test('pump: an absent time zone stays absent — never null, never a guess', async () => {
  const seen: Record<string, unknown>[] = []
  const controller = { async prompt(request: Record<string, unknown>) { seen.push(request); return { accepted: true as const } } }
  await pumpPrompt(controller, {
    requestId: 'r-1', sessionId: 's', mode: 'queue',
    content: [{ type: 'text', text: 'hi' }],
  })
  assert.equal('clientTimeZone' in (seen[0] ?? {}), false)
})

test('pump: any not-found namespace folds to unknown-session; other failures rethrow', async () => {
  const failing = (thrown: unknown) => ({ async prompt() { throw thrown } })
  const prompt = { requestId: 'r-1', sessionId: 's', mode: 'queue' as const, content: [{ type: 'text' as const, text: 'hi' }] }
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
