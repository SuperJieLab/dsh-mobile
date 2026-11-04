/**
 * The forwarded-events source: one `$events` identity, its generation, and fan-out.
 *
 * The fake is a stream shaped like the runtime's — `ready` first (with the clientId),
 * then whatever the test pushes; it ends when the test breaks it. Nothing here knows
 * about approvals: that is `write.test.ts`, which subscribes to this.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ForwardedEvents } from '../../src/upstream/remote-events.ts'
import type { UpstreamWireFrame } from '../../src/ports/events.ts'
import { fakeEventStream, until } from './fake-events.ts'

// -- fixtures ----------------------------------------------------------------

/** A sink that records what it was told, in order. */
function recorder() {
  const generations: (number | undefined)[] = []
  const frames: UpstreamWireFrame[] = []
  return {
    generations,
    frames,
    generation(generation: number | undefined): void { generations.push(generation) },
    frame(frame: UpstreamWireFrame): void { frames.push(frame) },
  }
}

async function liveSource(options: { failFirstOpen?: boolean } = {}) {
  const feed = fakeEventStream(options)
  const events = new ForwardedEvents(feed.source)
  events.start(AbortSignal.timeout(10_000))
  await feed.started
  // 开流是异步的：`started` 只说明「body 跑到了这里」，`ready` 由消费方才算数。
  if (options.failFirstOpen !== true) await until(() => events.ready, 'the source is ready')
  return { feed, events, stop: () => events.stop() }
}

const EMIT: UpstreamWireFrame = { type: 'emit', event: 'api-session/added', args: ['s1'] }

// -- judgements --------------------------------------------------------------

test('the source announces generation 1 and hands every frame to every subscriber', async () => {
  const { feed, events, stop } = await liveSource()
  const one = recorder()
  const two = recorder()
  events.subscribe(one)
  events.subscribe(two)
  try {
    // 订阅发生在源就绪之后，所以这次 `ready` 的扇出没有观众 —— 订阅不补发状态，
    // 消费方自己读 `generation`（开口帧不许等源）。
    assert.equal(events.generation, 1)
    assert.equal(events.clientId, 'client-1')
    assert.equal(events.ready, true)

    feed.push(EMIT)
    await until(() => one.frames.length === 1 && two.frames.length === 1, 'both subscribers get the frame')
    assert.deepEqual(one.frames, [EMIT])
    assert.deepEqual(two.frames, [EMIT], 'the same frame, unchanged — the fan-out does not filter')
  } finally {
    stop()
  }
})

test('a live subscription hears a new generation, and only once', async () => {
  const { feed, events, stop } = await liveSource()
  try {
    const late = recorder()
    events.subscribe(late)
    // 让源换代：当前这一代收尾 → 退避 → 下一代 ready。
    feed.end()
    await until(() => late.generations.length === 2, 'lost, then rebuilt')
    assert.deepEqual(late.generations, [undefined, 2],
      'the loss is announced as "no generation", and the counter continues where it stopped')
    assert.equal(events.generation, 2)
    assert.equal(events.clientId, 'client-2', 'a new source is a new identity')
  } finally {
    stop()
  }
})

test('an identity that dies takes its generation with it', async () => {
  const { feed, events, stop } = await liveSource()
  try {
    assert.equal(events.ready, true)
    feed.end()
    await until(() => !events.ready, 'the source is marked gone')
    assert.equal(events.generation, undefined, 'a source that is not there has no generation — not "the old one"')
    assert.equal(events.clientId, undefined)
  } finally {
    stop()
  }
})

test('unsubscribing stops the flow for that subscriber only', async () => {
  const { feed, events, stop } = await liveSource()
  const staying = recorder()
  const leaving = recorder()
  events.subscribe(staying)
  const unsubscribe = events.subscribe(leaving)
  try {
    unsubscribe()
    feed.push(EMIT)
    await until(() => staying.frames.length === 1, 'the remaining subscriber gets the frame')
    assert.deepEqual(leaving.frames, [], 'a subscriber that left hears nothing more')
  } finally {
    stop()
  }
})

test('a subscriber that throws does not cost the others their source', async () => {
  const { feed, events, stop } = await liveSource()
  const healthy = recorder()
  events.subscribe({ generation() {}, frame() { throw new Error('subscriber bug') } })
  events.subscribe(healthy)
  try {
    feed.push(EMIT)
    await until(() => healthy.frames.length === 1, 'the healthy subscriber still gets the frame')
    // 关键的一半：源没有被判死（否则宿主会重投全部待答问题、代次白跳一次）。
    assert.equal(events.ready, true)
    assert.equal(events.generation, 1)
    assert.equal(feed.opened, 1, 'no reconnect was provoked by the throwing subscriber')
  } finally {
    stop()
  }
})

test('a source that fails to open is retried, and the identity comes back', async () => {
  const { feed, events, stop } = await liveSource({ failFirstOpen: true })
  try {
    // 500 ms 首次退避；按次数等到第二代接上。
    await until(() => events.ready, 'the second generation serves normally')
    assert.equal(feed.opened, 2, 'the failure was retried instead of leaving the source dead')
    assert.equal(events.generation, 1, 'only a ready source counts as a generation — a failed open does not')
  } finally {
    stop()
  }
})
