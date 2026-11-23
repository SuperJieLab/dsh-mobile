/**
 * 打开帧的两头：进来的是上游的 `request` 形，出去的是上游 `snapshot` 原样。
 *
 * 这一期起网关**不再组装**打开帧 —— 窗口怎么切是宿主的事，我们只转达。所以这里的判据
 * 只有两类：入参收不收（判据 1），出帧是不是逐字那份（判据 3、4）。任何一条「我们
 * 自己算出来的字段」都会让第一条红。
 *
 * 判据 3 的键集合是**穷举**的：多一格（比如又塞回 `model` 或 `pageStart`）与少一格
 * （漏了 `header`）一样红 —— 两种都让手机端与 Web UI 看到的不是同一份东西。
 *
 * Run: node --test tests/remote/follow-opening.test.ts
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { attachStreamHandler } from '../../src/remote/server.ts'
import type { FollowSource } from '../../src/ports/follow.ts'
import { connect, event, fakeSource, filler, receive, send, snapshotFrame, turn } from './harness.ts'

/**
 * 客户端该发的入参 —— 上游 `SessionFollowRequest` 的形状，外加宿主方法的 `request` 容器
 * （宿主的形参就是一个对象，见 `requestContainerOf`）。
 *
 * 里面每个可选键都写全：判据 1 要证明的是「这些键都收下并原样交给宿主」，缺席的键证明
 * 不了这一件事。
 */
const OPENING_ARGS = {
  request: {
    address: { kind: 'session', sessionId: 's-1' },
    activate: true,
    assistantStream: true,
    maxMessages: 500,
    turnWindow: { minMessages: 50, minTurns: 2 },
  },
}

/** 一条流的一生：起服、连、发 open、交给 `body`、收场。 */
async function withStream(
  args: unknown,
  source: FollowSource,
  body: (socket: WebSocket) => Promise<void>,
  options: { openingCapBytes?: number } = {},
): Promise<void> {
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) }, options)
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args } })
    await body(socket)
    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
}

// MARK: - 判据 1：入参

test('判据 1: the upstream request shape is accepted and reaches the host verbatim', { timeout: 10_000 }, async () => {
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  await withStream(OPENING_ARGS, source, async (socket) => {
    const opening = await receive(socket)
    assert.equal(opening.type, 'item', '这一条入参必须被认下来')
    // **直传的判据**：宿主收到的样子就是客户端发的那份。多一格（网关补的默认值）、
    // 少一格（网关只认自己记得的键）、或换名（`address` → `sessionId`）都算改了它。
    assert.deepEqual(source.requests, [OPENING_ARGS.request])
  })
})

test('判据 1: the flat shape of the previous phase is refused as invalid-args', { timeout: 10_000 }, async () => {
  // 少一层 `request` 容器、地址也是裸的 `sessionId` —— 上一期的形状。静默当空对象收下
  // 会让它看起来能用（而宿主一个字段都没收到），所以拒。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  await withStream({ sessionId: 's-1' }, source, async (socket) => {
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.error as { code?: string }).code, 'invalid-args')
    assert.equal(source.calls, 0, '被拒的入参不该惊动宿主')
  })
})

test('判据 1: an address kind this phase does not implement is refused, not guessed', { timeout: 10_000 }, async () => {
  // `subagent` 在 spec 范围外。猜一个 `sessionId` 出来会让手机去读一个不该读的会话 ——
  // 拒比猜诚实，而且拒得出来才说明 `address` 真的是判别联合、不是裸 id。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const args = { request: { ...OPENING_ARGS.request, address: { kind: 'subagent', sessionId: 's-1' } } }
  await withStream(args, source, async (socket) => {
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.error as { code?: string }).code, 'invalid-args')
    assert.equal(source.calls, 0)
  })
})

test('判据 1: a malformed window is refused instead of dropped on the floor', { timeout: 10_000 }, async () => {
  // `maxMessages: 0` 与 `turnWindow.minTurns: "2"` 都发不到宿主：前者会被宿主读成
  // 「默认值」、后者到宿主那一侧才炸 —— 两种都比在这里拒晚。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  for (const broken of [
    { request: { ...OPENING_ARGS.request, maxMessages: 0 } },
    { request: { ...OPENING_ARGS.request, turnWindow: { minMessages: 50 } } },
    { request: {} },
  ]) {
    await withStream(broken, source, async (socket) => {
      const refusal = await receive(socket)
      assert.equal(refusal.type, 'error', `${JSON.stringify(broken)} 该被拒`)
      assert.equal((refusal.error as { code?: string }).code, 'invalid-args')
    })
  }
  assert.equal(source.calls, 0)
})

// MARK: - 判据 3：出帧

test('判据 3: the opening is the host snapshot verbatim — same keys, same values, no assembly', { timeout: 10_000 }, async () => {
  const log = [0, 1, 2].map(event)
  const source = fakeSource([snapshotFrame(log, 3)])
  await withStream(OPENING_ARGS, source, async (socket) => {
    const frame = await receive(socket)
    assert.equal(frame.type, 'item')
    const payload = frame.value as Record<string, unknown>

    // 键集合穷举：`assistantStream` 宿主没给，所以它缺席（不是 `undefined`）。
    assert.deepEqual(Object.keys(payload).sort(),
      ['cursor', 'hasMore', 'header', 'projections', 'records', 'type'],
      '打开帧的键集合就是宿主 snapshot 的键集合')
    for (const gone of ['sessionId', 'pageStart', 'hasOlder', 'model', 'events']) {
      assert.equal(gone in payload, false, `网关自己算的 "${gone}" 不该再出现`)
    }

    // 记录仍是 `{type:'event', event}`：剥层是客户端的事，网关不动。
    const records = payload.records as { type?: string; event?: { seq?: number } }[]
    assert.deepEqual(records.map(record => record.type), ['event', 'event', 'event'])
    assert.deepEqual(records.map(record => record.event?.seq), [0, 1, 2])

    // `cursor` **含端**、原样：网关不再 `+1`（换算在客户端入口一处做）。
    assert.equal(payload.cursor, 2, 'cursor 是宿主给的含端上界')
  })
})

test('判据 3: the optional assistant baseline rides along when the host sends it', { timeout: 10_000 }, async () => {
  const baseline = { revision: 3, attempt: { attemptId: 'a-1', nextIndex: 2 } }
  const source = fakeSource([snapshotFrame([event(0)], 1, { assistantStream: baseline })])
  await withStream(OPENING_ARGS, source, async (socket) => {
    const payload = (await receive(socket)).value as Record<string, unknown>
    assert.deepEqual(payload.assistantStream, baseline, '可选字段原样随行')
    assert.deepEqual(Object.keys(payload).sort(),
      ['assistantStream', 'cursor', 'hasMore', 'header', 'projections', 'records', 'type'])
  })
})

// MARK: - 判据 4：字节收窄

test('判据 4: an oversize window is cut on a turn boundary, and hasMore says so', { timeout: 10_000 }, async () => {
  // 上游的窗口只按消息数切，不保证字节；一条 WS 消息的上界仍在网关这一侧。
  const log = [turn(0), filler(1, 300), turn(2), filler(3, 300)]
  const source = fakeSource([snapshotFrame(log, 4)])
  await withStream(OPENING_ARGS, source, async (socket) => {
    const frame = await receive(socket)
    const wire = Buffer.byteLength(JSON.stringify(frame), 'utf8')
    assert.ok(wire <= 900, `这一帧要装进上界（实际 ${wire}）`)

    const payload = frame.value as { records: { event: { type: string; seq: number } }[]; hasMore: boolean; cursor: number }
    assert.equal(payload.records.length, 2, '按轮收窄：留下一整轮')
    assert.equal(payload.records[0].event.type, 'turn/start', '起点落在轮边界上')
    assert.equal(payload.records[0].event.seq, 2, '装得下的最早那一轮')
    // **裁了就要说还有**：否则「窗口被裁」与「日志到头」在客户端长得一样，
    // 往回翻页的入口永远不会出现。
    assert.equal(payload.hasMore, true, '裁掉的部分必须标成还有')
    assert.equal(payload.cursor, 3, 'cursor 是宿主覆盖到哪，不随裁而变')
  }, { openingCapBytes: 900 })
})

test('判据 4: a window that fits is not cut, and the host hasMore is kept as it was', { timeout: 10_000 }, async () => {
  const log = [turn(0), filler(1, 10)]
  const source = fakeSource([snapshotFrame(log, 2)])
  await withStream(OPENING_ARGS, source, async (socket) => {
    const payload = (await receive(socket)).value as { records: unknown[]; hasMore: boolean }
    assert.equal(payload.records.length, 2, '装得下就不动它')
    assert.equal(payload.hasMore, false, '宿主说没有了，就是没有了 —— 不因为这一层没裁而改口')
  }, { openingCapBytes: 1_000_000 })
})
