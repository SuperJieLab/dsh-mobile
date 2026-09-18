/**
 * Seam tests for the protocol: one wire message in, one wire message out.
 *
 * These tests are the reason `handle` exists as a standalone function. They run
 * with `node --test src/rpc.test.ts` — no server, no DSH runtime, no filesystem,
 * no network. The data source is injected, so every case below is decided by
 * the protocol layer alone.
 *
 * Run: node --test src/rpc.test.ts
 * See docs/protocol.md and docs/plans/M1-lan-mvp.md §4.3 Step 3.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { handle } from './rpc.ts'
import type { SessionPort, SessionSummary, WireEvent } from './rpc.ts'

/** One fake session: the summary the list path sees, and the log the read path sees. */
interface FakeSession {
  summary: SessionSummary
  events: readonly WireEvent[]
}

/** An in-memory {@link SessionPort} — the seam's only dependency, fully controlled. */
function fakePort(sessions: readonly FakeSession[] = []): SessionPort {
  const byId = new Map(sessions.map(session => [session.summary.id, session]))
  return {
    async list() {
      return sessions.map(session => session.summary)
    },
    async read(id, since) {
      const found = byId.get(id)
      if (found === undefined) return undefined
      const events = found.events.filter(event => event.seq >= since)
      const last = events.at(-1)
      return { events, asOfSeq: last === undefined ? since : last.seq + 1 }
    },
  }
}

/** A minimal event. `data` is opaque to the protocol layer by design. */
function event(seq: number): WireEvent {
  return { type: 'user/message', seq, time: 1_758_000_000_000 + seq, data: { body: `#${seq}` } }
}

/** A session summary with the two optional-looking fields made explicit. */
function summary(id: string, updatedAt: number, title?: string): SessionSummary {
  return { id, ...(title === undefined ? {} : { title }), createdAt: 1_758_000_000_000, updatedAt, eventCount: 2 }
}

const CLOCK = () => 1_758_000_999_999

test('an unknown version is refused and the refusal still carries v', async () => {
  const response = await handle({ v: 2, op: 'list-sessions' }, fakePort(), CLOCK)
  assert.equal(response.v, 1)
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
  for (const message of [{ v: 1, op: 'delete-everything' }, { v: 1 }, { v: 1, op: 7 }]) {
    const response = await handle(message, fakePort(), CLOCK)
    assert.equal(response.ok, false)
    assert.equal('error' in response && response.error.code, 'unknown-op')
  }
})

test('list-sessions answers with serverTime and every summary field it promised', async () => {
  const response = await handle({ v: 1, op: 'list-sessions' }, fakePort([
    { summary: summary('s-1', 100, 'First'), events: [event(0), event(1)] },
  ]), CLOCK)

  assert.deepEqual(response, {
    v: 1,
    ok: true,
    serverTime: 1_758_000_999_999,
    sessions: [{ id: 's-1', title: 'First', createdAt: 1_758_000_000_000, updatedAt: 100, eventCount: 2 }],
  })
})

test('a session without a title omits the field instead of sending null', async () => {
  const response = await handle({ v: 1, op: 'list-sessions' }, fakePort([
    { summary: summary('s-1', 100), events: [] },
  ]), CLOCK)

  assert.equal(response.ok, true)
  const sessions = response.ok ? (response as { sessions: unknown[] }).sessions : []
  assert.deepEqual(sessions, [{ id: 's-1', createdAt: 1_758_000_000_000, updatedAt: 100, eventCount: 2 }])
  assert.equal('title' in (sessions[0] as object), false)
})

test('sessions are ordered most-recently-updated first', async () => {
  const response = await handle({ v: 1, op: 'list-sessions' }, fakePort([
    { summary: summary('older', 100), events: [] },
    { summary: summary('newest', 300), events: [] },
    { summary: summary('middle', 200), events: [] },
  ]), CLOCK)

  const sessions = response.ok ? (response as { sessions: { id: string }[] }).sessions : []
  assert.deepEqual(sessions.map(session => session.id), ['newest', 'middle', 'older'])
})

test('snapshot with since 0 returns the whole log and reports the next expected seq', async () => {
  const response = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { summary: summary('s-1', 100), events: [event(0), event(1), event(2)] },
  ]), CLOCK)

  assert.equal(response.ok, true)
  assert.deepEqual(response, {
    v: 1,
    ok: true,
    sessionId: 's-1',
    asOfSeq: 3,
    events: [event(0), event(1), event(2)],
  })
})

test('snapshot returns only seq >= since', async () => {
  const response = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: 2 }, fakePort([
    { summary: summary('s-1', 100), events: [event(0), event(1), event(2), event(3)] },
  ]), CLOCK)

  const events = response.ok ? (response as { events: WireEvent[] }).events : []
  assert.deepEqual(events.map(e => e.seq), [2, 3])
  assert.equal(response.ok && (response as { asOfSeq: number }).asOfSeq, 4)
})

test('the water-mark invariant: replaying asOfSeq as since yields nothing and moves nothing', async () => {
  const port = fakePort([{ summary: summary('s-1', 100), events: [event(0), event(1), event(2)] }])

  const first = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  const waterMark = first.ok ? (first as { asOfSeq: number }).asOfSeq : -1

  const second = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: waterMark }, port, CLOCK)
  assert.equal(second.ok, true)
  assert.deepEqual((second as { events: WireEvent[] }).events, [])
  assert.equal((second as { asOfSeq: number }).asOfSeq, waterMark)
})

test('an absent or nonsense since is treated as 0 rather than inventing an error code', async () => {
  const port = fakePort([{ summary: summary('s-1', 100), events: [event(0), event(1)] }])

  for (const since of [undefined, -5, 1.5, 'x', null]) {
    const response = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since }, port, CLOCK)
    assert.equal(response.ok, true)
    assert.deepEqual((response as { events: WireEvent[] }).events.map(e => e.seq), [0, 1])
  }
})

test('an unknown session is refused with unknown-session, including a non-string id', async () => {
  for (const sessionId of ['nope', '', 42, undefined, null]) {
    const response = await handle({ v: 1, op: 'snapshot', sessionId, since: 0 }, fakePort(), CLOCK)
    assert.equal(response.ok, false)
    assert.equal('error' in response && response.error.code, 'unknown-session')
  }
})

test('a session the runtime cannot interpret is refused with unreadable-session', async () => {
  const port: SessionPort = {
    async list() { return [] },
    async read() { throw Object.assign(new Error('unreadable'), { name: 'SessionFormatUnsupportedError' }) },
  }
  const response = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  assert.equal(response.ok, false)
  assert.equal('error' in response && response.error.code, 'unreadable-session')
})

test('events are passed through verbatim, unknown fields included', async () => {
  const enriched: WireEvent = { ...event(0), ignorable: true, futureField: { nested: [1, 2] } }
  const response = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: 0 }, fakePort([
    { summary: summary('s-1', 100), events: [enriched] },
  ]), CLOCK)

  assert.deepEqual((response as { events: WireEvent[] }).events, [enriched])
})

test('an unexpected data-source failure surfaces as a refusal, not a crash', async () => {
  const port: SessionPort = {
    async list() { throw new Error('disk on fire') },
    async read() { throw new Error('disk on fire') },
  }
  const listed = await handle({ v: 1, op: 'list-sessions' }, port, CLOCK)
  assert.equal(listed.ok, false)
  assert.equal('error' in listed && listed.error.code, 'internal-error')

  const read = await handle({ v: 1, op: 'snapshot', sessionId: 's-1', since: 0 }, port, CLOCK)
  assert.equal(read.ok, false)
  assert.equal('error' in read && read.error.code, 'internal-error')
})

test('every response the seam can produce carries v', async () => {
  const messages = [
    { v: 2, op: 'list-sessions' },
    { v: 1, op: 'nope' },
    { v: 1, op: 'list-sessions' },
    { v: 1, op: 'snapshot', sessionId: 's-1', since: 0 },
    { v: 1, op: 'snapshot', sessionId: 'missing', since: 0 },
  ]
  for (const message of messages) {
    const response = await handle(message, fakePort([{ summary: summary('s-1', 100), events: [] }]), CLOCK)
    assert.equal(response.v, 1, `v missing for ${JSON.stringify(message)}`)
  }
})
