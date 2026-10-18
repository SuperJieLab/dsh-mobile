/**
 * 流帧的编解码（两端共守的那一半）。
 *
 * 这里只测形状与解析：帧怎么被切窗口、opening 怎么装配，都住在 `protocol/`。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { encodeServerFrame, followRequestOf, parseClientFrame } from '../../src/wire/mux.ts'

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
  // `as const` 保留 `type` 的字面量：宽化后它与 `MuxServerFrame` 的判别式对不上，
  // 而这几个字面量正是「每种帧都过得去」的样本。
  const item = { type: 'item', streamId: 1, payload: { type: 'event', seq: 0 } } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(item)), item)

  const error = { type: 'error', streamId: 1, payload: { code: 'unknown-session', message: 'no stored session' } } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(error)), error)

  const end = { type: 'end', streamId: 3 } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(end)), end)
})
