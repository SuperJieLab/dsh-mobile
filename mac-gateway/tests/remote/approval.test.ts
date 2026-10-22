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
 * 后者由 `structure.test.ts` 的 W7（三种 `kind` 只允许在 `write.ts` 出现）与真机现象守。
 */

import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { test } from 'node:test'

import { attachStreamHandler } from '../../src/remote/server.ts'
import { broadcasterOver } from '../../src/upstream/faces.ts'
import { ForwardedEvents } from '../../src/upstream/remote-events.ts'
import { ApprovalRelay, type RemoteEventAnswerLike } from '../../src/upstream/write.ts'
import type { UpstreamWireFrame } from '../../src/ports/events.ts'
import { connect, fakeSource, receive } from './harness.ts'
import { fakeEventStream, until } from '../upstream/fake-events.ts'

const answered: unknown[] = []

/** 结果门：这一条不关心应答，但要给它一个能构造的对象。 */
const door: RemoteEventAnswerLike = {
  async dispatchRpc(_endpoint, payload) {
    answered.push(payload)
    return { ok: true, value: undefined }
  },
}

async function harness() {
  const feed = fakeEventStream()
  const events = new ForwardedEvents(feed.source)
  const face = broadcasterOver()
  const relay = new ApprovalRelay(events, door, face, AbortSignal.timeout(20_000))
  events.start(AbortSignal.timeout(20_000))

  const server = createServer()
  const broadcaster = attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, {
    events,
    onClientConnected: (send) => {
      for (const frame of relay.replayFrames()) send(frame)
    },
  })
  face.connect((frame) => broadcaster.broadcast(frame))
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

test('approval: a live request reaches the socket with its session, as bytes', { timeout: 20_000 }, async () => {
  const h = await harness()
  try {
    const socket = await connect(h.server)
    // 每条连接一接上就先收一份对账名单（此刻是空的）—— 既有行为，不是本期的。
    const ledger = await receive(socket)
    assert.equal((ledger.payload as { kind?: string }).kind, 'sync')

    h.feed.push(approvalRequest('e1', 'session-7'))

    const frame = await receive(socket)
    assert.deepEqual(frame, {
      type: 'approval',
      payload: {
        kind: 'request', eventId: 'e1', sessionId: 'session-7',
        toolName: 'shell', reason: 'needs write',
      },
    })
    socket.close()
  } finally {
    h.close()
  }
})

test('approval: a client that connects later gets the ledger first, then the question', { timeout: 20_000 }, async () => {
  const h = await harness()
  try {
    // 先挂上一条，再让客户端接入 —— 这正是「手机离线期间到达的审批」那个处境。
    // 等 `held()` 而不是等墙钟：推送进了源的队列，由泵下一拍才交到中继。
    h.feed.push(approvalRequest('e1', 'session-7'))
    await until(() => h.relay.held().length === 1, 'the question is held before the client arrives')

    const socket = await connect(h.server)

    const ledger = await receive(socket)
    assert.deepEqual(ledger, {
      type: 'approval',
      payload: { kind: 'sync', eventIds: ['e1'], callIds: [] },
    }, 'the ledger comes first: a request before it would be swept away by it')

    const request = await receive(socket)
    assert.equal((request.payload as { kind?: string }).kind, 'request')
    assert.equal((request.payload as { sessionId?: string }).sessionId, 'session-7',
      'the replay carries the identity — this is the half a live-only field would silently miss')
    socket.close()
  } finally {
    h.close()
  }
})
