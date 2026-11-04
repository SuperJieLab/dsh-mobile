/**
 * 流帧的编解码（两端共守的那一半）。
 *
 * 这里只测形状与解析：帧怎么被切窗口、opening 怎么装配，都住在 `protocol/`。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { encodeServerFrame, followRequestOf, openRequestOf, parseClientFrame } from '../../src/wire/mux.ts'

test('parseClientFrame: round-trips the client frame shapes', () => {
  const open = parseClientFrame(JSON.stringify({
    type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' },
  }))
  assert.deepEqual(open, { type: 'open', streamId: 's1', payload: { op: 'follow', sessionId: 's1' } })

  const cancel = parseClientFrame(JSON.stringify({ type: 'cancel', streamId: 's2' }))
  assert.deepEqual(cancel, { type: 'cancel', streamId: 's2' })
})

test('parseClientFrame: refuses only what cannot be attributed to a stream', () => {
  // 判据是**编号在不在手**，不是内容坏到什么程度：这些帧读不出「属于哪条流」，
  // 于是连一条可拒收它的流都没有 —— 只能以传输层 close 应对。
  const refusals = [
    'not json at all',
    '{}',
    'null',
    '[1,2]',
    // 编号只在字符串上有意义：数字会被读成「1 号流」那种用途槽位，正是要拆掉的形态。
    JSON.stringify({ type: 'open', streamId: 1, payload: { sessionId: 's1' } }),
    JSON.stringify({ type: 'open', streamId: '', payload: { sessionId: 's1' } }),
    JSON.stringify({ type: 'subscribe', streamId: 's1', payload: {} }),     // unknown type
    JSON.stringify({ type: 'item', streamId: 's1', payload: {} }),          // server-only type
    JSON.stringify({ v: 2, op: 'snapshot', sessionId: 's1' }),           // an HTTP message is not a frame
  ]
  for (const text of refusals) assert.equal(parseClientFrame(text), undefined, `should refuse: ${text}`)
})

test('parseClientFrame: a bad payload is still a frame — the envelope is all this layer judges', () => {
  // 这三条**都归得上一条流**（编号在手），所以不在这里拒：坏的是内容，不是这一帧。
  // 由 `onClientText` 回一条带该编号的 `unknown-op`，连接与别的流都不动 ——
  // 若它们在这里返回 `undefined`，一个新 op 就会被当成「不是协议」而断掉整条连接。
  const attributable = [
    JSON.stringify({ type: 'open', streamId: 's1' }),                       // open without payload
    JSON.stringify({ type: 'open', streamId: 's1', payload: {} }),          // no sessionId
    JSON.stringify({ type: 'open', streamId: 's1', payload: { op: 'nosuch' } }),
    JSON.stringify({ type: 'open', streamId: 's1', payload: { op: 'events' } }),
  ]
  for (const text of attributable) {
    const frame = parseClientFrame(text)
    assert.equal(frame?.type, 'open', `should parse as a frame: ${text}`)
    assert.equal(frame?.streamId, 's1', `the id survives, whatever the payload says: ${text}`)
    // 载荷这一层仍然拒它 —— 分界两边的判据都在，缺一边就等于把洞挪个位置。
    assert.equal(followRequestOf((frame as { payload: unknown }).payload), undefined,
      `the payload is not a follow request: ${text}`)
  }
})

test('followRequestOf: op is part of the request; lenient on maxMessages, strict on sessionId', () => {
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1' }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 9 }), { sessionId: 's1', maxMessages: 9 })
  // Nonsense sizes degrade to the default — the worst case is one wasted window.
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 0 }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: -3 }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 1.5 }), { sessionId: 's1' })
  assert.deepEqual(followRequestOf({ op: 'follow', sessionId: 's1', since: 42 }), { sessionId: 's1' }, 'extra fields ignored')
  // `follow` 是这条校验认得的那一个 op；`events` 的判定在 `openRequestOf`。
  assert.equal(followRequestOf({ sessionId: 's1' }), undefined, 'missing op')
  assert.equal(followRequestOf({ op: 'snapshot', sessionId: 's1' }), undefined, 'an HTTP op is not a stream op')
  assert.equal(followRequestOf(undefined), undefined)
  assert.equal(followRequestOf('s1'), undefined)
})

test('openRequestOf: the op names which stream, and only two ops have a stream', () => {
  // 信封（`parseClientFrame`）只说「几号流」，这里说「这条流要什么」。
  assert.deepEqual(openRequestOf({ op: 'follow', sessionId: 's1' }), { kind: 'follow', sessionId: 's1' })
  assert.deepEqual(openRequestOf({ op: 'follow', sessionId: 's1', maxMessages: 9 }), { kind: 'follow', sessionId: 's1', maxMessages: 9 })
  assert.deepEqual(openRequestOf({ op: 'events' }), { kind: 'events' })
  // 缺会话名的 follow 不是一条开得起来的流；HTTP 的 op 同理。
  assert.equal(openRequestOf({ op: 'follow' }), undefined)
  assert.equal(openRequestOf({ op: 'snapshot', sessionId: 's1' }), undefined)
  assert.equal(openRequestOf({ op: 'nosuch' }), undefined)
  assert.equal(openRequestOf(undefined), undefined)
  assert.equal(openRequestOf('s1'), undefined, 'a bare string is not a payload with an op')
})

test('encodeServerFrame: every server frame round-trips through JSON', () => {
  // `as const` 保留 `type` 的字面量：宽化后它与 `MuxServerFrame` 的判别式对不上，
  // 而这几个字面量正是「每种帧都过得去」的样本。
  const item = { type: 'item', streamId: 's1', payload: { type: 'event', seq: 0 } } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(item)), item)

  const error = { type: 'error', streamId: 's1', payload: { code: 'unknown-session', message: 'no stored session' } } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(error)), error)

  const end = { type: 'end', streamId: 's3' } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(end)), end)
})
