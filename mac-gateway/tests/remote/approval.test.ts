/**
 * 审批在**真线上**的样子：真监听器、真 WebSocket、真的中继，源是假的。
 *
 * 为什么这条要单独一个文件而不并进 `upstream/write.test.ts`：那边验的是中继交出的**变更**，
 * 这一条验的是那些变更经流泵组帧、`encodeServerFrame` 之后**字节真的到了 socket 另一端**。
 * 两者中间隔着整个传输层 —— 形状对、内容对，仍然可能因为装配漏了一步而什么都不发。
 *
 * 装配照 `src/index.ts` 的接线来：中继先建（它要在第一个客户端接入前就订阅源），然后
 * 与 `events` 成对交给 `attachStreamHandler` —— 审批的投递通道只有 `{op:'events'}` 这一条。
 *
 * 覆盖不到的一半（写在代码里而不是留给下一个人猜）：本文件装配的是**它自己**的那一份
 * 接线，所以它证明的是「这段接线能 work」，不是「`index.ts` 里那段一定接了」。
 * 后者由 `structure.test.ts` 的「每个 kind 只构造一次」与真机现象守。
 */

import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { test } from 'node:test'

import { attachStreamHandler } from '../../src/remote/server.ts'
import { ForwardedEvents } from '../../src/upstream/remote-events.ts'
import { ApprovalRelay, type RemoteEventAnswerLike } from '../../src/upstream/write.ts'
import type { UpstreamWireFrame } from '../../src/ports/events.ts'
import { connect, fakeFeed, fakeSource, receive, send } from './harness.ts'
import { fakeEventStream, until } from '../upstream/fake-events.ts'
import type { ApprovalSource, HeldApproval } from '../../src/ports/approval.ts'

/** 结果门：这一条不关心应答，只要能构造出中继要的那个对象。 */
const door: RemoteEventAnswerLike = {
  async dispatchRpc() {
    return { ok: true, value: undefined }
  },
}

async function harness() {
  const feed = fakeEventStream()
  const events = new ForwardedEvents(feed.source)
  const relay = new ApprovalRelay(events, door, AbortSignal.timeout(20_000))
  events.start(AbortSignal.timeout(20_000))

  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, {
    // 审批的投递通道只有这一条：待答项随 `{op:'events'}` 的流走。
    events,
    approvals: relay,
  })
  server.listen(0)
  await once(server, 'listening')
  await feed.started
  await until(() => events.ready, 'the source is ready')

  return {
    feed,
    relay,
    server,
    close(): void {
      events.stop()
      server.closeAllConnections()
      server.close()
    },
  }
}

function approvalRequest(eventId: string, sessionId: string): UpstreamWireFrame {
  return {
    type: 'waterfall', event: 'approval/request', eventId,
    agentId: sessionId, request: { toolName: 'shell', reason: 'needs write' },
  }
}

/** 一条待答调用，四个字段与上游 waterfall 逐字相同。 */
function held(eventId: string, sessionId = 'session-7'): HeldApproval {
  return {
    event: 'approval/request', eventId, agentId: sessionId,
    request: { toolName: 'shell', reason: 'needs write' },
  }
}

/**
 * 一个**由测试拨动**的审批集合。
 *
 * `ready` 是它唯一的开关，而它决定流泵给不给基线 —— 这是本文件唯一碰不到的东西：
 * 真中继的 `ready` 跟着 `$events` 身份走，测试没法让它停在 false 又不触发别的副作用。
 * 集合内容与变化回调都照 `ApprovalSource` 如实实现，不伪造语义。
 */
function fakeApprovals(options: { ready: boolean; held?: HeldApproval[] }): ApprovalSource & {
  push: (item: HeldApproval) => void
  cancel: (eventId: string) => void
  setReady: (ready: boolean) => void
} {
  const heldItems = [...(options.held ?? [])]
  const listeners = new Set<(item: HeldApproval) => void>()
  const cancelListeners = new Set<(eventId: string) => void>()
  let ready = options.ready
  return {
    get ready() { return ready },
    held: () => heldItems,
    onHeld(listener) {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    onCancelled(listener) {
      cancelListeners.add(listener)
      return () => { cancelListeners.delete(listener) }
    },
    push(item) {
      heldItems.push(item)
      for (const listener of listeners) listener(item)
    },
    cancel(eventId) {
      const index = heldItems.findIndex(item => item.eventId === eventId)
      if (index >= 0) heldItems.splice(index, 1)
      for (const listener of cancelListeners) listener(eventId)
    },
    setReady(value) { ready = value },
  }
}

/** 起一个只有事件流的网关：`events` 与 `approvals` 由调用方给。 */
async function eventsOnlyServer(events: ReturnType<typeof fakeFeed>, approvals: ApprovalSource) {
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, { events, approvals })
  server.listen(0)
  await once(server, 'listening')
  return server
}

test('approval: a live request reaches the socket as a stream item', { timeout: 20_000 }, async () => {
  const h = await harness()
  try {
    const socket = await connect(h.server)
    // 开口即基线：先一条 ready。此刻集合为空，所以它后面没有 waterfall。
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })
    const ready = await receive(socket)
    assert.equal((ready.payload as { kind?: string }).kind, 'ready')

    h.feed.push(approvalRequest('e1', 'session-7'))

    const frame = await receive(socket)
    assert.deepEqual(frame, {
      type: 'item',
      streamId: 'ev',
      payload: {
        kind: 'waterfall', event: 'approval/request', eventId: 'e1',
        agentId: 'session-7', request: { toolName: 'shell', reason: 'needs write' },
      },
    })
    socket.close()
  } finally {
    h.close()
  }
})

test('approval: a client that opens later gets the question with the opening baseline', { timeout: 20_000 }, async () => {
  const h = await harness()
  try {
    // 先挂上待答项，再让客户端开流 —— 这正是「手机离线期间到达的审批」那个处境。
    // 等 `held()` 而不是等墙钟：推送进了源的队列，由泵下一拍才交到中继。
    h.feed.push(approvalRequest('e1', 'session-7'))
    await until(() => h.relay.held().length === 1, 'the question is held before the client arrives')

    const socket = await connect(h.server)
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })

    // ready 之后紧跟当前集合 —— 没有单独的名单帧，「基线与这条流从哪里开始」是同一件事。
    const ready = await receive(socket)
    assert.equal((ready.payload as { kind?: string }).kind, 'ready')

    const replay = await receive(socket)
    const payload = replay.payload as { kind?: string; agentId?: string }
    assert.equal(payload.kind, 'waterfall')
    assert.equal(payload.agentId, 'session-7',
      'the replay carries the identity — this is the half a live-only field would silently miss')
    socket.close()
  } finally {
    h.close()
  }
})

test('approval: an upstream cancel reaches the socket as stream cargo', { timeout: 20_000 }, async () => {
  // 契约的另一半：`waterfall` 让卡出现，`cancel` 让它消失。只守前者的话，「中继收到了撤回
  // 却没往流上发」全绿 —— 而症状是别人先答了之后这张卡永远留着，正是本期要消灭的那种残留。
  const h = await harness()
  try {
    const socket = await connect(h.server)
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })
    await receive(socket) // ready

    h.feed.push(approvalRequest('e1', 'session-7'))
    await until(() => h.relay.held().length === 1, 'the question is held before the cancel')
    assert.equal(((await receive(socket)).payload as { eventId?: string }).eventId, 'e1')

    h.feed.push({ type: 'cancel', eventId: 'e1' })
    const gone = await receive(socket)
    assert.deepEqual(gone.payload, { kind: 'cancel', eventId: 'e1' },
      'a question settled elsewhere must take its card down — this is the other half of the contract')
    assert.deepEqual(h.relay.held(), [], 'and the held set loses it, so the next opening baseline is honest')
    socket.close()
  } finally {
    h.close()
  }
})

test('A1/B1: the opening replays the whole set in order, and later arrivals follow it', { timeout: 20_000 }, async () => {
  // 三条断言合起来是「开口即基线」这一个承诺：集合全在、顺序是到达序、增量排在重放之后。
  // 少任何一条，症状都是「卡片莫名少一张或闪一下」，而两端各自的判据都还是绿的。
  const approvals = fakeApprovals({ ready: true, held: [held('e1'), held('e2', 'session-8')] })
  const server = await eventsOnlyServer(fakeFeed(), approvals)
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })

    const ready = await receive(socket)
    assert.equal((ready.payload as { kind?: string }).kind, 'ready',
      'the opening baseline starts with `ready` — nothing precedes it')

    const replayed = [
      (await receive(socket)).payload as { eventId?: string },
      (await receive(socket)).payload as { eventId?: string },
    ]
    assert.deepEqual(replayed.map(item => item.eventId), ['e1', 'e2'],
      'the baseline is the whole current set, in arrival order')

    approvals.push(held('e3'))
    assert.equal(((await receive(socket)).payload as { eventId?: string }).eventId, 'e3',
      'a later arrival follows the replay — it does not replace it')
    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('A1/B1: an empty set gives `ready` and nothing else — there is no ledger frame', { timeout: 20_000 }, async () => {
  // 「空集合也要发一份基线」是旧形态（名单帧）留下的直觉。现在的答案是：基线就是这一份重放，
  // 集合空则它空 —— 多一条帧就等于多一个客户端要判「这份东西可信吗」的地方。
  const approvals = fakeApprovals({ ready: true })
  const server = await eventsOnlyServer(fakeFeed(), approvals)
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })

    assert.equal(((await receive(socket)).payload as { kind?: string }).kind, 'ready')

    // 确定性写法：不赌「一段时间内没有帧」，而是让下一帧必须就是刚推的那条。
    approvals.push(held('e1'))
    const next = await receive(socket)
    assert.equal((next.payload as { kind?: string }).kind, 'waterfall',
      'ready 与第一条增量之间不该夹着任何一帧 —— 夹着的那一帧就是被删掉的名单')
    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('B3: reopening the stream puts the whole set on the wire again', { timeout: 20_000 }, async () => {
  // 「恢复」只有一条路径：重新开一次流。客户端那边因此不需要记「上次收到哪一条」——
  // 每次开口都是一份完整基线，按 `eventId` 覆盖即可。断掉一半的重放（只补新的）会让
  // 这条承诺变成「客户端得自己补齐」，而那正是两边判据都绿、真机上少一张卡的形状。
  const approvals = fakeApprovals({ ready: true, held: [held('e1'), held('e2')] })
  const server = await eventsOnlyServer(fakeFeed(), approvals)
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev1', payload: { op: 'events' } })
    for (let index = 0; index < 3; index += 1) await receive(socket)

    send(socket, { type: 'cancel', streamId: 'ev1' })
    send(socket, { type: 'open', streamId: 'ev2', payload: { op: 'events' } })

    const frames = [await receive(socket), await receive(socket), await receive(socket)]
    assert.equal((frames[0]!.payload as { kind?: string }).kind, 'ready')
    assert.deepEqual(frames.slice(1).map(frame => (frame.payload as { eventId?: string }).eventId),
      ['e1', 'e2'], 'a reopened stream gets the same complete baseline, not the delta since the last one')
    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('B2: opening before the source is ready is refused — a stale baseline is worse than none', { timeout: 20_000 }, async () => {
  // 中继此刻不知道上游还挂着什么。给一份「看起来有」的集合，客户端会把它当成可信基线，
  // 随后按它把表重建 —— 那张表就是错的，而且没有任何东西会让它变回来。
  const approvals = fakeApprovals({ ready: false })
  const server = await eventsOnlyServer(fakeFeed(), approvals)
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })

    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error', 'a stream that can only lie must be refused, not opened')
    assert.equal(refusal.streamId, 'ev', 'the refusal lands on that stream alone')
    assert.equal((refusal.payload as { code?: string }).code, 'source-unavailable',
      'this code is the retryable half: the source usually is ready by the next attempt')

    // 拒绝之后编号被收回：再开同一个编号不该被当成协议违规（那会直接断掉连接）。
    approvals.setReady(true)
    send(socket, { type: 'open', streamId: 'ev', payload: { op: 'events' } })
    assert.equal(((await receive(socket)).payload as { kind?: string }).kind, 'ready',
      'the refused stream left nothing behind — the same id opens cleanly')
    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
