/**
 * 审批在**真线上**的样子：真监听器、真 WebSocket、真的中继，源是假的。
 *
 * 为什么这条要单独一个文件而不并进 `upstream/write.test.ts`：那边验的是中继对「假广播切面」
 * 说了什么，这一条验的是那句话经 `encodeServerFrame` 之后**字节真的到了 socket 另一端**。
 * 两者中间隔着整个传输层 —— 形状对、内容对，仍然可能因为装配漏了一步而什么都不发。
 *
 * 装配照 `src/index.ts` 的接线来：中继先建（它要在第一个客户端接入前就订阅源），
 * `broadcaster` 由 `attachStreamHandler` 返回后再接到中继的广播切面上。这个顺序是既有
 * 设计的约束（socket 集合要等监听器起来才存在），不是这里自己发明的。
 *
 * 覆盖不到的一半（写在代码里而不是留给下一个人猜）：本文件装配的是**它自己**的那一份
 * `onClientConnected`，所以它证明的是「这段接线能work」，不是「`index.ts` 里那段一定接了」。
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
import { connect, fakeSource, receive, send } from './harness.ts'
import { fakeEventStream, until } from '../upstream/fake-events.ts'

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
