/**
 * 流帧的编解码（两端共守的那一半）。
 *
 * 这里只测形状与解析：帧怎么被切窗口、opening 怎么装配，都住在 `protocol/`。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { encodeServerFrame, openRequestOf, parseClientFrame, type MuxErrorFrame } from '../../src/wire/mux.ts'
import { readFileSync } from 'node:fs'

test('parseClientFrame: round-trips the client frame shapes', () => {
  const open = parseClientFrame(JSON.stringify({
    type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { sessionId: 's1' } },
  }))
  assert.deepEqual(open, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { sessionId: 's1' } } })

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
  // 这几条**都归得上一条流**（编号在手），所以不在这里拒：坏的是内容，不是这一帧。
  // 端点层的判定（`unknown-endpoint` / `invalid-args`）由 `openRequestOf` 的测试守，
  // 这里只守**信封**：编号在、`type` 在，就不该把整条连接判死。
  const attributable = [
    JSON.stringify({ type: 'open', streamId: 's1' }),                       // open without payload
    JSON.stringify({ type: 'open', streamId: 's1', payload: {} }),          // no endpoint at all
    JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'nosuch/x', payload: { args: {} } }),
    JSON.stringify({ type: 'open', streamId: 's1', endpoint: '$events', payload: { args: {} } }),
  ]
  for (const text of attributable) {
    const frame = parseClientFrame(text)
    assert.equal(frame?.type, 'open', `should parse as a frame: ${text}`)
    assert.equal(frame?.streamId, 's1', `the id survives, whatever the payload says: ${text}`)
    // 载荷层另有判据（`openRequestOf` 的测试），这里不断言它 —— 分界两边的判据各在各处。

  }
})


test('openRequestOf: 端点说这条流要什么，参数在 payload.args 里', () => {
  // 信封（`parseClientFrame`）只说「几号流」，这里说「这条流要什么」。四个端点各有
  // 自己的请求形状：`session/follow` 带一份上游的 `request`，另三条没有入参。
  //
  // 请求**嵌一层**：摊平的话 `kind` 会跟着请求一起被转给宿主，而宿主的形参只有
  // `SessionFollowRequest` 的那几个键。
  const follow = {
    address: { kind: 'session', sessionId: 's1' },
    activate: true,
    assistantStream: true,
    maxMessages: 9,
  }
  assert.deepEqual(
    openRequestOf({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: { request: follow } } }),
    { kind: 'follow', request: follow },
  )
  assert.deepEqual(
    openRequestOf({
      type: 'open', streamId: 's1', endpoint: 'session/follow',
      payload: { args: { request: { address: { kind: 'session', sessionId: 's1' } } } },
    }),
    { kind: 'follow', request: { address: { kind: 'session', sessionId: 's1' } } },
    '可缺省的键不补默认值 —— 收到几格就是几格',
  )
  assert.deepEqual(
    openRequestOf({ type: 'open', streamId: 's1', endpoint: '$events', payload: { args: {} } }),
    { kind: 'events' },
  )
  assert.deepEqual(
    openRequestOf({ type: 'open', streamId: 's1', endpoint: 'session/control', payload: { args: {} } }),
    { kind: 'control' },
  )
  // 名字不在表里与「名字对、参数不对」是两个失败，都不关连接。
  assert.deepEqual(
    openRequestOf({ type: 'open', streamId: 's1', endpoint: 'session/approvals', payload: { args: {} } }),
    { error: 'unknown-endpoint' },
  )
  assert.deepEqual(
    openRequestOf({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: {} } }),
    { error: 'invalid-args' },
  )
  assert.deepEqual(
    openRequestOf({ type: 'open', streamId: 's1', endpoint: undefined, payload: { args: {} } }),
    { error: 'unknown-endpoint' },
    '缺端点等于名字不在表里，不是畸形帧',
  )
})

test('encodeServerFrame: every server frame round-trips through JSON', () => {
  // `as const` 保留 `type` 的字面量：宽化后它与 `MuxServerFrame` 的判别式对不上，
  // 而这几个字面量正是「每种帧都过得去」的样本。
  const item = { type: 'item', streamId: 's1', value: { type: 'event', seq: 0 } } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(item)), item)

  const error = {
    type: 'error',
    streamId: 's1',
    error: { code: 'unknown-session', message: 'no stored session', details: {} },
  } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(error)), error)

  const end = { type: 'end', streamId: 's3' } as const
  assert.deepEqual(JSON.parse(encodeServerFrame(end)), end)
})

test('MuxServerFrame: 第三格改名后，旧的字段名被类型拒绝', () => {
  // 判据是**编译期**的：类型一旦放宽，`@ts-expect-error` 会报「未使用的豁免」而红。
  // 这与上面的 JSON 往返不同 —— 那个对任何对象都成立，守不住字段名。
  // @ts-expect-error item 的第三格叫 value，不再接受 payload
  encodeServerFrame({ type: 'item', streamId: 's1', payload: {} })
  // @ts-expect-error error 帧的第三格叫 error
  encodeServerFrame({ type: 'error', streamId: 's1', payload: { code: 'x', message: 'y' } })
})

test('error 帧少一格 details 编译不过 —— 三键是必填的', () => {
  // 这条替代原先那条恒真的「恰好三键」：输入自己写三键、`encodeServerFrame` 就是
  // `JSON.stringify`，那种断言与实现无关。真正会退化的是**类型把 `details` 改成可选** ——
  // 那时下面这行不再报错，`@ts-expect-error` 变成「未使用的指令」而 `tsc` 失败。
  // @ts-expect-error 缺 details 必须被拒
  const missing: MuxErrorFrame = { type: 'error', streamId: 's1', error: { code: 'x', message: 'y' } }
  assert.equal(missing.type, 'error')
})

// ---------------------------------------------------------------------------
// 服务端帧的三种种类
//
// error 对象恰好三键没有行为判据：原先那条测试自己写三键字面量再断言三键，
// 而 `encodeServerFrame` 就是 `JSON.stringify` —— 它只证明「字面量是三键」，与实现无关。
// 「少一格」由 `MuxErrorFrame.error` 的三个必填字段挡（上一节 `@ts-expect-error` 那组
// 已经在证明它），「多一格」没有任何构造点可以产生。故删除，不由测试承担。
// ---------------------------------------------------------------------------

test('服务端帧只有 item / error / end 三种 —— 共享样本里不出现 usage', () => {
  // 帧种类是契约：多一种就得多一条判据、多一处消费者；`usage` 那一种本期退役，
  // 它的读数改走投影通道（`session/control`）。样本是两端共守的那份，从它查最实。
  const fixture = JSON.parse(readFileSync(new URL('../../../contract/mux-frames.json', import.meta.url), 'utf8')) as {
    server: { type: string }[]
  }
  const types = new Set(fixture.server.map(sample => sample.type))
  assert.deepEqual([...types].sort(), ['end', 'error', 'item'], '服务端帧的种类多出或少掉了一种')
})
