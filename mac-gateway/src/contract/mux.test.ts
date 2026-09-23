/**
 * Stream contract tests.
 *
 * The headline test is S1 (docs/dev/plans/M2-realtime-transient.md §5.1): the same
 * window, encoded once through the HTTP `page` path and once through the follow
 * opening, must serialize **character-for-character identically**. That is the
 * executable form of the first protocol discipline — "the protocol is defined
 * as messages, not as URLs" — witnessed at the exact moment a second carrier
 * appears. If this test ever fails, the discipline was already broken upstream
 * of it, which is precisely what it is here to catch.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { handle } from './rpc.ts'
import {
  DEFAULT_FOLLOW_MESSAGES,
  encodeServerFrame,
  followOpening,
  followRequestOf,
  parseClientFrame,
} from './mux.ts'
import type { SessionPort, WireEvent } from './rpc.ts'

/** A dense fake log with unicode, extra fields, and both message types. */
function fakeLog(): WireEvent[] {
  return Array.from({ length: 120 }, (_, index) => ({
    type: index % 2 === 0 ? 'user/message' : 'assistant/message',
    seq: index,
    time: 1_700_000_000_000 + index,
    data: { text: `消息 ${index}`, nested: { at: index, tail: '—尾—' } },
    extra: { opaque: true },
  }))
}

/**
 * A log with real turn boundaries: every turn is `user/message`, `turn/start`,
 * `assistant/message`, `turn/end`.
 *
 * `followOpening`'s geometry is only meaningful against a log that has turns:
 * a window's start is aligned back to one (spec §8.5 B6 二次裁决), and a log
 * with no `turn/start` anywhere can only exercise the ceiling.
 */
function turnedLog(turns: number): WireEvent[] {
  const events: WireEvent[] = []
  const at = (type: string): void => {
    events.push({ type, seq: events.length, time: 1_700_000_000_000 + events.length, data: {} })
  }
  for (let turn = 0; turn < turns; turn += 1) {
    at('user/message')
    at('turn/start')
    at('assistant/message')
    at('turn/end')
  }
  return events
}

/** How many of these events count as messages when a boundary is drawn. */
function messageCount(events: readonly WireEvent[]): number {
  return events.filter(event => event.type === 'user/message' || event.type === 'assistant/message').length
}

/**
 * Only the log matters here: every case below reaches the port through the
 * `page` path, which reads the whole log (`readAll`). `list` / `read` are
 * placeholders — this file does not exercise those paths, and a second copy of
 * the slicing rule would be one more thing to keep in step with `rpc.ts`.
 */
function fakePort(log: readonly WireEvent[]): SessionPort {
  return {
    async list() { return [] },
    async read() { return undefined },
    async readAll(id) { return id === 's1' ? log : undefined },
  }
}

test('S1: a page reply and a follow opening serialize the same window identically', async () => {
  const log = fakeLog()
  const port = fakePort(log)

  // The HTTP path: one message in, one message out.
  const reply = await handle({ v: 2, op: 'page', sessionId: 's1' }, port)
  assert.ok(reply.ok, 'page should succeed')
  const pageEvents = (reply as { events: readonly WireEvent[] }).events

  // The stream path: the same log through the follow opening.
  const opening = followOpening({ sessionId: 's1' }, log)

  // Character-for-character — the pass-through is the point.
  assert.equal(JSON.stringify(opening.events), JSON.stringify(pageEvents))
  // Same window geometry, independently computed by each path.
  assert.equal(opening.pageStart, (reply as { pageStart: number }).pageStart)
  assert.equal(opening.hasOlder, (reply as { hasOlder: boolean }).hasOlder)
})

test('S1: the identity also holds for an explicitly sized, verbatim-typed window', async () => {
  const log = fakeLog()
  const port = fakePort(log)
  const reply = await handle({ v: 2, op: 'page', sessionId: 's1', maxMessages: 7 }, port)
  assert.ok(reply.ok)
  const opening = followOpening({ sessionId: 's1', maxMessages: 7 }, log)
  assert.equal(JSON.stringify(opening.events), JSON.stringify((reply as { events: WireEvent[] }).events))
})

test('followOpening: geometry — the start lands on a turn, cursor at the log end', () => {
  const log = turnedLog(40) // 160 events, 80 messages, 40 turns
  const opening = followOpening({ sessionId: 's1' }, log)

  assert.equal(opening.cursor, log.length, 'cursor is the exclusive log end')
  assert.equal(opening.hasOlder, true, 'only a tail window taken')
  // The count stops somewhere inside a turn; the window's start is walked back
  // to that turn's own opening, so no window opens on a half turn.
  assert.equal(log[opening.pageStart]?.type, 'turn/start')
  assert.equal(opening.events[0]?.seq, opening.pageStart)
  assert.equal(opening.events.at(-1)?.seq, log.length - 1)
  assert.deepEqual(opening.events, log.slice(opening.pageStart))
  // The target is a floor, and the ceiling keeps the walk bounded.
  assert.ok(messageCount(opening.events) >= DEFAULT_FOLLOW_MESSAGES, 'the default target is a floor')
  assert.ok(messageCount(opening.events) <= DEFAULT_FOLLOW_MESSAGES * 2, 'and twice it is the ceiling')
})

test('followOpening: an explicit maxMessages moves the boundary — still onto a turn', () => {
  const log = turnedLog(40)
  const wide = followOpening({ sessionId: 's1', maxMessages: 60 }, log)
  assert.equal(log[wide.pageStart]?.type, 'turn/start')
  assert.ok(messageCount(wide.events) >= 60, 'a wider target really does widen the window')

  const narrow = followOpening({ sessionId: 's1', maxMessages: 1 }, log)
  assert.equal(log[narrow.pageStart]?.type, 'turn/start')
  assert.ok(messageCount(narrow.events) >= 1)
  assert.ok(narrow.events.length < wide.events.length, 'the explicit sizes really do differ')
  assert.equal(narrow.hasOlder, true)
})

test('followOpening: default window size matches the page default', async () => {
  const log = fakeLog()
  const port = fakePort(log)
  const reply = await handle({ v: 2, op: 'page', sessionId: 's1' }, port)
  assert.ok(reply.ok)
  const opening = followOpening({ sessionId: 's1' }, log)
  assert.equal(DEFAULT_FOLLOW_MESSAGES, 50)
  assert.equal(opening.events.length, (reply as { events: WireEvent[] }).events.length)
})

test('parseClientFrame: round-trips the client frame shapes', () => {
  const open = parseClientFrame(JSON.stringify({
    type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' },
  }))
  assert.deepEqual(open, { type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } })

  const cancel = parseClientFrame(JSON.stringify({ type: 'cancel', streamId: 2 }))
  assert.deepEqual(cancel, { type: 'cancel', streamId: 2 })
})

test('parseClientFrame: refuses everything that is not a well-formed client frame', () => {
  const refusals = [
    'not json at all',
    '{}',
    'null',
    '[1,2]',
    JSON.stringify({ type: 'open', streamId: 1 }),                       // open without payload
    JSON.stringify({ type: 'open', streamId: 1, payload: {} }),          // no sessionId
    JSON.stringify({ type: 'open', streamId: 1, payload: { sessionId: '' } }),
    JSON.stringify({ type: 'open', streamId: 1, payload: { sessionId: 7 } }),
    JSON.stringify({ type: 'open', streamId: 1.5, payload: { sessionId: 's1' } }),
    JSON.stringify({ type: 'open', streamId: '1', payload: { sessionId: 's1' } }),
    JSON.stringify({ type: 'subscribe', streamId: 1, payload: {} }),     // unknown type
    JSON.stringify({ type: 'item', streamId: 1, payload: {} }),          // server-only type
    JSON.stringify({ v: 2, op: 'snapshot', sessionId: 's1' }),           // an HTTP message is not a frame
  ]
  for (const text of refusals) assert.equal(parseClientFrame(text), undefined, `should refuse: ${text}`)
})

test('followRequestOf: op is part of the request; lenient on maxMessages, strict on sessionId', () => {
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1' }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 9 }), { sessionId: 's1', maxMessages: 9 })
  // Nonsense sizes degrade to the default — the worst case is one wasted window.
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 0 }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: -3 }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 1.5 }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', since: 42 }), { sessionId: 's1' }, 'extra fields ignored')
  // M2 has exactly one stream op; anything else is not a follow request.
  assert.equal(followRequestOf({ sessionId: 's1' }), undefined, 'missing op')
  assert.equal(followRequestOf({ op: 'snapshot', sessionId: 's1' }), undefined, 'an HTTP op is not a stream op')
  assert.equal(followRequestOf(undefined), undefined)
  assert.equal(followRequestOf('s1'), undefined)
})

test('encodeServerFrame: every server frame round-trips through JSON', () => {
  const item = { type: 'item', streamId: 1, payload: { type: 'event', seq: 0 } }
  assert.deepEqual(JSON.parse(encodeServerFrame(item)), item)

  const error = { type: 'error', streamId: 1, payload: { code: 'unknown-session', message: 'no stored session' } }
  assert.deepEqual(JSON.parse(encodeServerFrame(error)), error)

  const end = { type: 'end', streamId: 3 }
  assert.deepEqual(JSON.parse(encodeServerFrame(end)), end)
})

test('regression: the window extraction kept both page refusals distinct', async () => {
  const port = fakePort(fakeLog())

  // A cursor past the end is a resync, not an unreadable log (M1 判据 P4).
  const pastEnd = await handle({ v: 2, op: 'page', sessionId: 's1', beforeSeq: 999 }, port)
  assert.ok(!pastEnd.ok && pastEnd.error.code === 'resync-required', JSON.stringify(pastEnd))

  // A sparse log is unreadable.
  const sparse = fakeLog().map((event, index) => index === 5 ? { ...event, seq: 99 } : event)
  const sparseReply = await handle({ v: 2, op: 'page', sessionId: 's1' }, fakePort(sparse))
  assert.ok(!sparseReply.ok && sparseReply.error.code === 'unreadable-session', JSON.stringify(sparseReply))
})
