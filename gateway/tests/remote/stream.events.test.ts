/**
 * `$events`：一条连接级流，四种货物。
 *
 * 与 `stream.test.ts` 的分工：那份守「一条 follow 流从 open 到 end 怎么走」，这份守
 * 「连接级流的那四种货物各自长什么样、以及它们的源不在了的时候谁受影响」。
 *
 * 四种货物在上游是同一条流上的四支：`ready`（带 `clientId`）、`emit`（原样转发）、
 * `waterfall` / `cancel`（来自审批中继）。**一条流装四种**是本期的结构决定 ——
 * 原来按恢复语义拆成三条，代价是与上游不同形、每加一类事件要开一条新流。
 * 合并的代价写在 `E2` 里：审批源未就绪时整条流开不起来。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { attachStreamHandler } from '../../src/remote/server.ts'
import type { ApprovalSource, HeldApproval } from '../../src/ports/approval.ts'
import type { Server } from 'node:http'
import { connect, fakeFeed, fakeSource, receive, send } from './harness.ts'

const firstHeld: HeldApproval = {
  event: 'approval/request', eventId: 'approve-1', agentId: 'session-a', request: { toolName: 'bash' },
}

/** 一份由测试驱动的待答集合：`ready` 与集合内容都在用例手里。 */
function approvalsOf(held: readonly HeldApproval[], ready = true): ApprovalSource {
  return {
    ready,
    held: () => [...held],
    onHeld: () => () => {},
    onCancelled: () => () => {},
  }
}

/** 假审批源，且能被推 —— 模拟中继在 `approval/request` 上做的事。 */
function relayedApprovals(): ApprovalSource & {
  push(held: HeldApproval): void
  cancel(eventId: string): void
} {
  const held = new Set<(held: HeldApproval) => void>()
  const cancelled = new Set<(eventId: string) => void>()
  return {
    ready: true,
    held: () => [],
    onHeld(listener) {
      held.add(listener)
      return () => { held.delete(listener) }
    },
    onCancelled(listener) {
      cancelled.add(listener)
      return () => { cancelled.delete(listener) }
    },
    push(item) { for (const listener of held) listener(item) },
    cancel(eventId) { for (const listener of cancelled) listener(eventId) },
  }
}

async function eventsServer(
  feed: ReturnType<typeof fakeFeed>,
  approvals: ApprovalSource,
): Promise<Server> {
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, { events: feed, approvals })
  server.listen(0)
  await once(server, 'listening')
  return server
}

test('E1: 开流先给 ready（带 clientId），紧跟全部待答项，之后实时到达', { timeout: 10_000 }, async () => {
  const approvals = relayedApprovals()
  const server = await eventsServer(fakeFeed(), approvals)
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } })

    const ready = await receive(socket)
    assert.equal(ready.type, 'item')
    const readyValue = ready.value as { type?: string; clientId?: string }
    assert.equal(readyValue.type, 'ready')
    assert.equal(typeof readyValue.clientId, 'string')
    assert.notEqual(readyValue.clientId, '', 'clientId 不是空串 —— 它是这条流的登记键')

    approvals.push(firstHeld)
    const live = await receive(socket)
    assert.equal((live.value as { type?: string }).type, 'waterfall')
    assert.equal((live.value as { eventId?: string }).eventId, 'approve-1')

    approvals.cancel('approve-1')
    const gone = await receive(socket)
    assert.deepEqual(gone.value, { type: 'cancel', eventId: 'approve-1' })

    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E2: 审批源未就绪 → 整条流被拒，而 follow 流照常', { timeout: 10_000 }, async () => {
  const feed = fakeFeed()
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, {
    events: feed,
    approvals: approvalsOf([], false),
  })
  server.listen(0)
  await once(server, 'listening')
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } })
    const refusal = await receive(socket)
    assert.equal(refusal.type, 'error')
    assert.equal((refusal.error as { code?: string }).code, 'source-unavailable')

    // 同一条连接上再开一条 follow：不被上一条的拒绝牵连。`fakeSource([])` 没有会话，
    // 它给一条空流并 `end` —— 关键是那一帧**属于它自己的编号**，连接没被整条关掉。
    send(socket, { type: 'open', streamId: 'f1', endpoint: 'session/follow', payload: { args: { sessionId: 'ghost' } } })
    const follow = await receive(socket)
    assert.equal(follow.streamId, 'f1', 'follow 的收尾是它自己的，不是被 $events 的拒绝连坐')

    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E3: emit 原样转发 —— 名字与参数都不解释', { timeout: 10_000 }, async () => {
  const feed = fakeFeed()
  const server = await eventsServer(feed, approvalsOf([]))
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } })
    await receive(socket) // ready

    // 连 `api-session/*` 也不翻 —— 那是客户端的事（R5）。
    feed.emit('api-session/status', ['session-a', true])
    const frame = await receive(socket)
    assert.deepEqual(frame.value, {
      type: 'emit', event: 'api-session/status', args: ['session-a', true],
    })
    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E4: 源换代 → 再发一条 ready，流不结束', { timeout: 10_000 }, async () => {
  const feed = fakeFeed()
  const server = await eventsServer(feed, approvalsOf([firstHeld]))
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } })

    const first = await receive(socket)
    assert.equal((first.value as { type?: string }).type, 'ready')
    const replay = await receive(socket)
    assert.equal((replay.value as { type?: string }).type, 'waterfall', 'ready 之后紧跟集合')

    feed.setGeneration(4)
    const again = await receive(socket)
    assert.equal((again.value as { type?: string }).type, 'ready', '换代后重发 ready，不是结束流')
    const replayAgain = await receive(socket)
    assert.equal((replayAgain.value as { type?: string }).type, 'waterfall', '集合随 ready 重发')

    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('E5: 四种货物落在同一条流上，编号相同', { timeout: 10_000 }, async () => {
  const feed = fakeFeed()
  const approvals = relayedApprovals()
  const server = await eventsServer(feed, approvals)
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'ev', endpoint: '$events', payload: { args: {} } })

    const kinds: string[] = []
    const collect = async (): Promise<void> => {
      const frame = await receive(socket)
      assert.equal(frame.streamId, 'ev', '四种货物共用这条流的编号')
      kinds.push((frame.value as { type?: string }).type ?? '?')
    }

    await collect() // ready
    approvals.push(firstHeld)
    await collect() // waterfall
    approvals.cancel('approve-1')
    await collect() // cancel
    feed.emit('commands/change', [])
    await collect() // emit

    assert.deepEqual(kinds, ['ready', 'waterfall', 'cancel', 'emit'])
    socket.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
