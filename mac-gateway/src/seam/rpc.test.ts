/**
 * Seam tests for the protocol: one wire message in, one wire message out.
 *
 * These tests are the reason `handle` exists as a standalone function. They run
 * with `node --test src/seam/rpc.test.ts` — no server, no DSH runtime, no filesystem,
 * no network. The data source is injected, so every case below is decided by
 * the protocol layer alone.
 *
 * Run: node --test src/seam/rpc.test.ts
 * See docs/dev/protocol.md and docs/dev/plans/M0-reachability-spike.md §4.3 Step 3.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { handle } from './rpc.ts'
import type { SessionPort, SessionRow, WireEvent } from './rpc.ts'

/** One fake session: the row the list path sees, and the log the read path sees. */
interface FakeSession {
  row: SessionRow
  events: readonly WireEvent[]
}

/** An in-memory {@link SessionPort} — the seam's only dependency, fully controlled. */
function fakePort(sessions: readonly FakeSession[] = []): SessionPort {
  const byId = new Map(sessions.map(session => [session.row.id, session]))
  return {
    async list() {
      return sessions.map(session => session.row)
    },
    async read(id, since, limit) {
      const found = byId.get(id)
      if (found === undefined) return undefined
      const remaining = found.events.filter(event => event.seq >= since)
      // The one shape the server *can* refuse: the client claims to have read
      // events, and the log holds none at all. A `since` merely past the water
      // mark is indistinguishable from "caught up" and stays a normal answer
      // (docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 5).
      if (remaining.length === 0 && since > 0 && found.events.length === 0) {
        return { events: [], asOfSeq: 0, hasMore: false, staleCursor: true }
      }
      const hasMore = remaining.length > limit
      const events = hasMore ? remaining.slice(0, limit) : remaining
      const last = events.at(-1)
      return { events, asOfSeq: last === undefined ? since : last.seq + 1, hasMore, staleCursor: false }
    },
    async readAll(id) {
      return byId.get(id)?.events
    },
  }
}

/** A minimal event. `data` is opaque to the protocol layer by design. */
function event(seq: number): WireEvent {
  return { type: 'user/message', seq, time: 1_758_000_000_000 + seq, data: { body: `#${seq}` } }
}

/**
 * A log where the even seqs are messages and the odd seqs are not.
 *
 * The mixture is what makes a window test meaningful: if the boundary were
 * drawn by event count, every case below would pass anyway.
 */
function mixedLog(count: number): WireEvent[] {
  return Array.from({ length: count }, (_, seq) =>
    seq % 2 === 0
      ? event(seq)
      : { type: 'policy/marker', seq, time: 1_758_000_000_000 + seq, data: {} },
  )
}

/** A list row with the optional field made explicit. */
function row(id: string, updatedAt: number, title?: string): SessionRow {
  return {
    id,
    ...(title === undefined ? {} : { title }),
    createdAt: 1_758_000_000_000,
    updatedAt,
    running: false,
    blank: false,
  }
}

const CLOCK = () => 1_758_000_999_999

/** Reply caps, small enough that every case below can observe them. */
function limits(maxDeltaEvents: number, maxDeltaBytes = 1_048_576): { maxDeltaEvents: number; maxDeltaBytes: number } {
  return { maxDeltaEvents, maxDeltaBytes }
}

test('an unknown version is refused and the refusal still carries v', async () => {
  const response = await handle({ v: 3, op: 'list-sessions' }, fakePort(), CLOCK)
  assert.equal(response.v, 2)
  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'unsupported-version')
})

test('a missing version is refused rather than assumed', async () => {
  const response = await handle({ op: 'list-sessions' }, fakePort(), CLOCK)
  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'unsupported-version')
})

test('a non-object message is refused without throwing', async () => {
  for (const message of [null, undefined, 42, 'list-sessions', [1, 2]]) {
    const response = await handle(message, fakePort(), CLOCK)
    assert.equal(response.ok, false)
    assert.equal('error' in response && response.error.code, 'unsupported-version')
  }
})

test('an unrecognized op is refused and a missing op is not guessed', async () => {
  for (const message of [{ v: 2, op: 'delete-everything' }, { v: 2 }, { v: 2, op: 7 }]) {
    const response = await handle(message, fakePort(), CLOCK)
    assert.equal(response.ok, false)
    assert.equal('error' in response && response.error.code, 'unknown-op')
  }
})

test('list-sessions answers with serverTime and every field a v2 row promises', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    { row: row('s-1', 100, 'First'), events: [event(0), event(1)] },
  ]), CLOCK)

  assert.deepEqual(response, {
    v: 2,
    ok: true,
    serverTime: 1_758_000_999_999,
    sessions: [{ id: 's-1', title: 'First', createdAt: 1_758_000_000_000, updatedAt: 100, running: false, blank: false }],
  })
})

test('a session without a title omits the field instead of sending null', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    { row: row('s-1', 100), events: [] },
  ]), CLOCK)

  assert.equal(response.ok, true)
  const sessions = response.ok ? (response as { sessions: unknown[] }).sessions : []
  assert.deepEqual(sessions, [{ id: 's-1', createdAt: 1_758_000_000_000, updatedAt: 100, running: false, blank: false }])
  assert.equal('title' in (sessions[0] as object), false)
})

test('sessions are ordered most-recently-updated first', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    { row: row('older', 100), events: [] },
    { row: row('newest', 300), events: [] },
    { row: row('middle', 200), events: [] },
  ]), CLOCK)

  const sessions = response.ok ? (response as { sessions: { id: string }[] }).sessions : []
  assert.deepEqual(sessions.map(session => session.id), ['newest', 'middle', 'older'])
})

test('snapshot with since 0 returns the whole log and reports the next expected seq', async () => {
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { row: row('s-1', 100), events: [event(0), event(1), event(2)] },
  ]), CLOCK)

  assert.equal(response.ok, true)
  assert.deepEqual(response, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    asOfSeq: 3,
    hasMore: false,
    events: [event(0), event(1), event(2)],
  })
})

test('snapshot returns only seq >= since', async () => {
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 2 }, fakePort([
    { row: row('s-1', 100), events: [event(0), event(1), event(2), event(3)] },
  ]), CLOCK)

  const events = response.ok ? (response as { events: WireEvent[] }).events : []
  assert.deepEqual(events.map(e => e.seq), [2, 3])
  assert.equal(response.ok && (response as { asOfSeq: number }).asOfSeq, 4)
})

test('the water-mark invariant: replaying asOfSeq as since yields nothing and moves nothing', async () => {
  const port = fakePort([{ row: row('s-1', 100), events: [event(0), event(1), event(2)] }])

  const first = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  const waterMark = first.ok ? (first as { asOfSeq: number }).asOfSeq : -1

  const second = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: waterMark }, port, CLOCK)
  assert.equal(second.ok, true)
  assert.deepEqual((second as { events: WireEvent[] }).events, [])
  assert.equal((second as { asOfSeq: number }).asOfSeq, waterMark)
})

test('an absent or nonsense since is treated as 0 rather than inventing an error code', async () => {
  const port = fakePort([{ row: row('s-1', 100), events: [event(0), event(1)] }])

  for (const since of [undefined, -5, 1.5, 'x', null]) {
    const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since }, port, CLOCK)
    assert.equal(response.ok, true)
    assert.deepEqual((response as { events: WireEvent[] }).events.map(e => e.seq), [0, 1])
  }
})

test('an unknown session is refused with unknown-session, including a non-string id', async () => {
  for (const sessionId of ['nope', '', 42, undefined, null]) {
    const response = await handle({ v: 2, op: 'snapshot', sessionId, since: 0 }, fakePort(), CLOCK)
    assert.equal(response.ok, false)
    assert.equal('error' in response && response.error.code, 'unknown-session')
  }
})

test('a session the runtime cannot interpret is refused with unreadable-session', async () => {
  const port: SessionPort = {
    async list() { return [] },
    async read() { throw Object.assign(new Error('unreadable'), { name: 'SessionFormatUnsupportedError' }) },
  }
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'unreadable-session')
})

test('events are passed through verbatim, unknown fields included', async () => {
  const enriched: WireEvent = { ...event(0), ignorable: true, futureField: { nested: [1, 2] } }
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { row: row('s-1', 100), events: [enriched] },
  ]), CLOCK)

  assert.deepEqual((response as { events: WireEvent[] }).events, [enriched])
})

test('an unexpected data-source failure surfaces as a refusal, not a crash', async () => {
  const port: SessionPort = {
    async list() { throw new Error('disk on fire') },
    async read() { throw new Error('disk on fire') },
  }
  const listed = await handle({ v: 2, op: 'list-sessions' }, port, CLOCK)
  assert.equal(listed.ok, false)
  assert.equal('error' in listed && listed.error.code, 'internal-error')

  const read = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  assert.equal(read.ok, false)
  assert.equal('error' in read && read.error.code, 'internal-error')
})

test('every response the seam can produce carries v', async () => {
  const messages = [
    { v: 2, op: 'list-sessions' },
    { v: 2, op: 'nope' },
    { v: 2, op: 'list-sessions' },
    { v: 2, op: 'snapshot', sessionId: 's-1', since: 0 },
    { v: 2, op: 'snapshot', sessionId: 'missing', since: 0 },
  ]
  for (const message of messages) {
    const response = await handle(message, fakePort([{ row: row('s-1', 100), events: [] }]), CLOCK)
    assert.equal(response.v, 2, `v missing for ${JSON.stringify(message)}`)
  }
})

test('a reply is capped at maxDeltaEvents and says so with hasMore', async () => {
  const port = fakePort([{ row: row('s-1', 100), events: [event(0), event(1), event(2)] }])

  const first = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK, limits(2))
  assert.deepEqual(first, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    asOfSeq: 2,
    hasMore: true,
    events: [event(0), event(1)],
  })

  const second = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 2 }, port, CLOCK, limits(2))
  assert.deepEqual(second, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    asOfSeq: 3,
    hasMore: false,
    events: [event(2)],
  })
})

test('chunked reads covering the log produce exactly the same view as one full read', async () => {
  const events = [event(0), event(1), event(2), event(3), event(4)]
  const port = fakePort([{ row: row('s-1', 100), events }])

  const whole = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  const wholeEvents = whole.ok ? (whole as { events: WireEvent[] }).events : []

  const collected: WireEvent[] = []
  let since = 0
  let rounds = 0
  for (;;) {
    rounds += 1
    assert.ok(rounds <= events.length + 1, 'chunked read did not terminate')
    const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since }, port, CLOCK, limits(2))
    assert.equal(response.ok, true)
    const batch = response as { events: WireEvent[]; asOfSeq: number; hasMore: boolean }
    collected.push(...batch.events)
    since = batch.asOfSeq
    if (!batch.hasMore) break
  }

  assert.deepEqual(collected, wholeEvents)
  assert.equal(since, 5, 'the last chunk must leave the cursor at the log end')
})

test('the byte cap is soft: the first event is delivered even when it alone exceeds it', async () => {
  const oversized: WireEvent = { ...event(0), data: { body: 'x'.repeat(4096) } }
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { row: row('s-1', 100), events: [oversized, event(1)] },
  ]), CLOCK, limits(100, 64))

  assert.equal(response.ok, true)
  const batch = response as { events: WireEvent[]; hasMore: boolean }
  assert.deepEqual(batch.events.map(e => e.seq), [0], 'a hard cap here would stall the client forever')
  assert.equal(batch.hasMore, true)
})

test('the byte cap trims the tail of a batch and reports hasMore', async () => {
  const bulky = (seq: number): WireEvent => ({ ...event(seq), data: { body: 'y'.repeat(200) } })
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { row: row('s-1', 100), events: [bulky(0), bulky(1), bulky(2)] },
  ]), CLOCK, limits(100, 250))

  const batch = response as { events: WireEvent[]; hasMore: boolean; asOfSeq: number }
  assert.deepEqual(batch.events.map(e => e.seq), [0], 'the events past the cap are held back, not split')
  assert.equal(batch.hasMore, true)
  assert.equal(batch.asOfSeq, 1)
})

test('an empty log with a positive since is refused with resync-required', async () => {
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 1 }, fakePort([
    { row: row('s-1', 100), events: [] },
  ]), CLOCK)

  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'resync-required')
})

test('an empty log with since 0 is an ordinary empty answer, not a resync', async () => {
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { row: row('s-1', 100), events: [] },
  ]), CLOCK)

  assert.deepEqual(response, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    asOfSeq: 0,
    hasMore: false,
    events: [],
  })
})

test('a since past the water mark is answered, not refused — it is indistinguishable from caught up', async () => {
  const response = await handle({ v: 2, op: 'snapshot', sessionId: 's-1', since: 999999 }, fakePort([
    { row: row('s-1', 100), events: [event(0), event(1)] },
  ]), CLOCK)

  assert.equal(response.ok, true)
  assert.deepEqual(response, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    asOfSeq: 999999,
    hasMore: false,
    events: [],
  })
})

// ---------------------------------------------------------------------------
// `page` — the backwards window (docs/dev/protocol.md §4.3)
// ---------------------------------------------------------------------------

test('page with no beforeSeq hands back the newest message window', async () => {
  const log = mixedLog(10)
  const response = await handle({ v: 2, op: 'page', sessionId: 's-1', maxMessages: 2 }, fakePort([
    { row: row('s-1', 100), events: log },
  ]), CLOCK)

  assert.deepEqual(response, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    pageStart: 6,
    asOfSeq: 10,
    hasOlder: true,
    // The whole interval, not just the two messages: a caller rendering
    // seq 6 needs seq 7 too, even though seq 7 is not a message itself.
    events: log.slice(6, 10),
  })
})

test('walking pages backwards covers the log exactly once', async () => {
  const log = mixedLog(10)
  const port = fakePort([{ row: row('s-1', 100), events: log }])

  const collected: number[] = []
  let beforeSeq: number | undefined
  let rounds = 0
  for (;;) {
    rounds += 1
    assert.ok(rounds <= 5, 'paging backwards did not terminate')
    const response = await handle({ v: 2, op: 'page', sessionId: 's-1', beforeSeq, maxMessages: 2 }, port, CLOCK)
    assert.equal(response.ok, true)
    const page = response as { events: WireEvent[]; pageStart: number; hasOlder: boolean }
    collected.unshift(...page.events.map(event => event.seq))
    if (!page.hasOlder) break
    beforeSeq = page.pageStart
  }

  assert.deepEqual(collected, log.map(event => event.seq), 'the pages must tile the log with no gap and no overlap')
})

test('a log with no messages at all is still a window, not an empty one', async () => {
  const log: WireEvent[] = [0, 1, 2].map(seq => ({ type: 'policy/marker', seq, time: 1, data: {} }))
  const response = await handle({ v: 2, op: 'page', sessionId: 's-1', maxMessages: 2 }, fakePort([
    { row: row('s-1', 100), events: log },
  ]), CLOCK)

  const page = response as { pageStart: number; asOfSeq: number; hasOlder: boolean; events: WireEvent[] }
  assert.equal(page.hasOlder, false)
  assert.deepEqual(page.events, log, 'a window that cannot be bounded by messages falls back to the whole log')
})

test('an empty log is an empty window rather than a refusal', async () => {
  const response = await handle({ v: 2, op: 'page', sessionId: 's-1' }, fakePort([
    { row: row('s-1', 100), events: [] },
  ]), CLOCK)

  assert.deepEqual(response, {
    v: 2,
    ok: true,
    sessionId: 's-1',
    pageStart: 0,
    asOfSeq: 0,
    hasOlder: false,
    events: [],
  })
})

test('page defaults to the protocol page size when maxMessages is absent', async () => {
  // 120 messages: more than the default, so an absent maxMessages is observable.
  const log: WireEvent[] = Array.from({ length: 120 }, (_, seq) => event(seq))
  const response = await handle({ v: 2, op: 'page', sessionId: 's-1' }, fakePort([
    { row: row('s-1', 100), events: log },
  ]), CLOCK)

  const page = response as { pageStart: number; hasOlder: boolean }
  assert.equal(page.hasOlder, true, 'an absent cap must not mean "everything"')
  assert.equal(page.pageStart, 70, 'the default leaves the newest 50 messages in the window')
})

test('a beforeSeq past the end of the log is refused, not silently clamped', async () => {
  const response = await handle({ v: 2, op: 'page', sessionId: 's-1', beforeSeq: 999 }, fakePort([
    { row: row('s-1', 100), events: mixedLog(10) },
  ]), CLOCK)

  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'resync-required')
})

test('a malformed beforeSeq falls back to the newest window rather than failing', async () => {
  for (const beforeSeq of [-1, 1.5, 'x', null]) {
    const response = await handle({ v: 2, op: 'page', sessionId: 's-1', beforeSeq, maxMessages: 2 }, fakePort([
      { row: row('s-1', 100), events: mixedLog(10) },
    ]), CLOCK)
    assert.equal(response.ok, true, `beforeSeq=${String(beforeSeq)} should degrade, not fail`)
    assert.equal((response as { pageStart: number }).pageStart, 6)
  }
})

test('page on an unknown session is the same refusal the read path uses', async () => {
  const response = await handle({ v: 2, op: 'page', sessionId: 'nope' }, fakePort(), CLOCK)
  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'unknown-session')
})

// ---------------------------------------------------------------------------
// `list-sessions` — the v2 row shape (docs/dev/protocol.md §4.1)
// ---------------------------------------------------------------------------

test('a list row carries running and blank, and never an event count', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    {
      row: { id: 's-1', title: '聊过的题目', createdAt: 1000, updatedAt: 2000, running: true, blank: false },
      events: [],
    },
  ]), CLOCK)

  assert.deepEqual(response, {
    v: 2,
    ok: true,
    serverTime: CLOCK(),
    sessions: [{ id: 's-1', title: '聊过的题目', createdAt: 1000, updatedAt: 2000, running: true, blank: false }],
  })
})

test('a row without a title omits the field rather than sending an empty one', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    { row: { id: 's-1', createdAt: 1000, updatedAt: 1000, running: false, blank: true }, events: [] },
  ]), CLOCK)

  const sessions = (response as { sessions: Record<string, unknown>[] }).sessions
  const first = sessions[0] ?? {}
  assert.equal('title' in first, false, 'no title is an absent key')
  // v1 promised this from the log, which is exactly what v2 gave up to stop reading it.
  assert.equal('eventCount' in first, false, 'an event count would put the log back on the list path')
  assert.equal(first.blank, true)
})

test('a subagent origin travels with the row so the client can hide it', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    { row: { id: 's-1', createdAt: 1000, updatedAt: 1000, running: false, blank: false, origin: 'subagent' }, events: [] },
    { row: row('s-2', 2000), events: [] },
  ]), CLOCK)

  const sessions = (response as { sessions: Record<string, unknown>[] }).sessions
  assert.equal(sessions.find(s => s.id === 's-1')?.origin, 'subagent')
  assert.equal('origin' in (sessions.find(s => s.id === 's-2') ?? {}), false, 'an ordinary session carries no origin')
})

test('rows are re-sorted newest first by the server, not by the client', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort([
    { row: row('older', 100), events: [] },
    { row: row('newer', 300), events: [] },
    { row: row('middle', 200), events: [] },
  ]), CLOCK)

  const sessions = (response as { sessions: { id: string }[] }).sessions
  assert.deepEqual(sessions.map(session => session.id), ['newer', 'middle', 'older'])
})
