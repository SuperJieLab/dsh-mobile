/**
 * 三条连接级流：各自的开口帧形态，以及互不带对方的货物。
 *
 * 为什么单独一份而不是并进 `stream.test.ts`：那份守的是「一条流从 open 到 end 怎么走」，
 * 这份守的是「一条流与另一条流会不会互相污染」。两者的失败面不同 —— 前者的 bug 是
 * 「这条流自己坏了」，后者是「一条流的事故连带另一条」，而后者正是本期要消掉的那一处。
 *
 * 三条流的词汇各自只有一类货物，所以「哪一帧该出现在哪条流上」在这里是可穷举的：
 * `approvals` 只有 `waterfall` / `cancel`，`session-list` 只有 `session-list`，
 * `host-events` 只有 `emit`。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { attachStreamHandler } from '../../src/remote/server.ts'
import type { ApprovalSource, HeldApproval } from '../../src/ports/approval.ts'
import type { Server } from 'node:http'
import { connect, fakeFeed, fakeSource, receive, send } from './harness.ts'

/** 一份由测试驱动的待答集合：`ready` 与集合内容都在用例手里。 */
function approvalsOf(held: readonly HeldApproval[], ready = true): ApprovalSource {
  return {
    ready,
    held: () => [...held],
    onHeld: () => () => {},
    onCancelled: () => () => {},
  }
}

const firstHeld: HeldApproval = {
  event: 'approval/request', eventId: 'approve-1', agentId: 'session-a', request: { toolName: 'bash' },
}

const secondHeld: HeldApproval = {
  event: 'approval/request', eventId: 'approve-2', agentId: 'session-b', request: { toolName: 'write_file' },
}

/**
 * 假审批源，且能被推一条 —— 模拟中继在 `approval/request` 上做的事。
 *
 * 审批不走源的 `frame` 通道：源上的 waterfall 先到中继（它要维护待答集合），再由中继
 * 通知每条开着的流。所以想验「审批帧只达审批流」，推力必须加在 `onHeld` 这一侧。
 */
function relayedApprovals(): ApprovalSource & { push(held: HeldApproval): void } {
  const listeners = new Set<(held: HeldApproval) => void>()
  return {
    ready: true,
    held: () => [],
    onHeld(listener) {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    onCancelled: () => () => {},
    push(held) {
      for (const listener of listeners) listener(held)
    },
  }
}

/** 起一台三条流都接得上的监听器；`feed` 与 `approvals` 由用例驱动。 */
async function splitServer(options: { held?: readonly HeldApproval[]; ready?: boolean } = {}): Promise<{
  feed: ReturnType<typeof fakeFeed>
  server: Server
}> {
  const feed = fakeFeed()
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, {
    events: feed,
    approvals: approvalsOf(options.held ?? [], options.ready ?? true),
  })
  server.listen(0)
  await once(server, 'listening')
  return { feed, server }
}

/** 收一帧并断言它属于哪条流、是什么货物 —— 三处都要看，只看一处会漏掉串流。 */
async function expectFrame(
  socket: WebSocket,
  streamId: string,
  kind: string,
): Promise<Record<string, unknown>> {
  const frame = await receive(socket)
  assert.equal(frame.streamId, streamId, `这一帧该在 ${streamId} 上，实际在 ${String(frame.streamId)} 上`)
  const payload = frame.value as Record<string, unknown> | undefined
  assert.equal(payload?.kind, kind, `${streamId} 上这一帧该是 ${kind}，实际 ${String(payload?.kind)}`)
  return payload ?? {}
}

// MARK: - 隔离：一条流的源坏了，另一条不陪着

test('U1: a session-list stream opens even when the approval source is not ready', { timeout: 10_000 }, async () => {
  // 这条是本期唯一的行为收益。共用的写法里 `approvals.ready === false` 会把**整条**
  // events 流拒掉，于是审批源的装配事故连带列表一起停 —— 手机上新删的会话再也看不到。
  const { feed, server } = await splitServer({ ready: false })
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'l1', payload: { op: 'session-list' } })
    assert.deepEqual(await expectFrame(socket, 'l1', 'ready'), { kind: 'ready' },
      '列表流的开口帧不带集合，也不该被审批源拖住')

    // 审批那条仍然被拒 —— 拒绝只落在它自己身上，这是「隔离」的另一半。
    send(socket, { type: 'open', streamId: 'a1', payload: { op: 'approvals' } })
    const refused = await receive(socket)
    assert.equal(refused.type, 'error')
    assert.equal(refused.streamId, 'a1')
    assert.equal((refused.error as Record<string, unknown>).code, 'source-unavailable')

    // 列表流还活着：拒绝之后源上的一条列表变化照样到达。
    feed.emit('api-session/removed', ['s1'])
    const change = await expectFrame(socket, 'l1', 'session-list')
    assert.deepEqual(change.change, { kind: 'removed', id: 's1' })

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

// MARK: - 开口帧的三种形态

test('U2: an approvals stream opens with ready, then the whole held set, in held order', { timeout: 10_000 }, async () => {
  // 「开口即基线」是审批唯一的恢复路径：客户端不持有跨代状态，每条 ready 之后重建一次表。
  // 顺序照 `held()` 给的来 —— 客户端按到达顺序排卡，网关重排一次就会与实时帧的顺序不一致。
  const { feed, server } = await splitServer({ held: [firstHeld, secondHeld] })
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'a1', payload: { op: 'approvals' } })
    assert.deepEqual(await expectFrame(socket, 'a1', 'ready'), { kind: 'ready' })

    const one = await expectFrame(socket, 'a1', 'waterfall')
    assert.equal(one.eventId, 'approve-1')
    const two = await expectFrame(socket, 'a1', 'waterfall')
    assert.equal(two.eventId, 'approve-2')

    // 源换代次 = 待答表重投：一条新 ready 加一份新集合。
    feed.setGeneration(4)
    assert.deepEqual(await expectFrame(socket, 'a1', 'ready'), { kind: 'ready', generation: 4 })
    assert.equal((await expectFrame(socket, 'a1', 'waterfall')).eventId, 'approve-1')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U3: a session-list ready carries the generation and nothing else', { timeout: 10_000 }, async () => {
  // 「就绪不建立存在性」：这条流的 ready 只说明「服务端已经开好这条流、源此刻是哪一代」，
  // 不携带任何集合。客户端据此发一次 list-sessions —— 与 Web UI 的 refreshList 同一条路。
  const { feed, server } = await splitServer()
  try {
    feed.setGeneration(7)
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'l1', payload: { op: 'session-list' } })
    assert.deepEqual(await expectFrame(socket, 'l1', 'ready'), { kind: 'ready', generation: 7 },
      'ready 只带代次；出现任何集合字段都说明这条流又开始承诺存在性了')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('U8: a host-events stream opens with ready and forwards emit verbatim', { timeout: 10_000 }, async () => {
  // 第三条流本期没有客户端订阅者，但它必须真的通 —— 否则「通道留着」只是画在文档上，
  // 将来接线的人要先花一天发现这条流根本收不到东西。
  const { feed, server } = await splitServer()
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'h1', payload: { op: 'host-events' } })
    assert.deepEqual(await expectFrame(socket, 'h1', 'ready'), { kind: 'ready' })

    feed.emit('commands/change', [{ name: 'compact' }])
    const payload = await expectFrame(socket, 'h1', 'emit')
    assert.equal(payload.event, 'commands/change')
    assert.deepEqual(payload.args, [{ name: 'compact' }], '名字与参数原样，网关不解释')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

// MARK: - 货物不串流

test('U4: each source frame reaches exactly one stream', { timeout: 10_000 }, async () => {
  // 三向都要看。只验一向的话，「泵把所有帧都转发给所有流」也能全绿 —— 那正是共用一条流
  // 时手机端的症状：审批卡出现在列表的通道里，而界面不显示它，只在日志里留下一个认不出。
  //
  // 审批那一向走的是**中继 → onHeld**，不是源的 `frame` 通道：源上的 waterfall 只有中继
  // 收（它要维护待答集合），再由中继通知每条开着的流。
  const relayed = relayedApprovals()
  const feed = fakeFeed()
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true }, { events: feed, approvals: relayed })
  server.listen(0)
  await once(server, 'listening')
  try {
    const socket = await connect(server)
    send(socket, { type: 'open', streamId: 'a1', payload: { op: 'approvals' } })
    send(socket, { type: 'open', streamId: 'l1', payload: { op: 'session-list' } })
    send(socket, { type: 'open', streamId: 'h1', payload: { op: 'host-events' } })
    for (const _id of ['a1', 'l1', 'h1']) await receive(socket) // 三条 ready

    assert.equal(feed.subscribers(), 3, '三条流三个订阅者；少一个说明有个泵没订上源')

    // 三帧依次发出，每一帧只该在它自己那条流上出现。审批那条同时验证：源上的 waterfall
    // 不会被列表或转发流收到（它们的回调只认 `emit`）。
    feed.push({ type: 'waterfall', event: 'approval/request', eventId: 'x1', agentId: 'session-a', request: {} })
    relayed.push(firstHeld)
    feed.emit('api-session/added', [{
      sessionId: 's9', updatedAt: 1_700_000_000_000, running: false, blank: false,
    }])
    feed.emit('llm/models-updated', [['deepseek-chat']])

    // 断言里带上 `event` 名：只看 `kind` 的话，「`pumpHostEvents` 漏了排除列表那几类」
    // 这个 bug 长得就像合规 —— 反正三条流各收到一帧，前三条里总有一条 `h1:emit`。
    // 真覆盖是「哪一条 emit」。
    const seen = [
      await receive(socket),
      await receive(socket),
      await receive(socket),
    ].map((frame) => {
      const payload = frame.value as Record<string, unknown>
      // 只有 `emit` 那一类带"转发的是哪个事件"；`waterfall` 的 `event` 是上游事件名，
      // 不是这里的判别项。
      const event = payload.kind === 'emit' ? `:${String(payload.event)}` : ''
      return `${String(frame.streamId)}:${String(payload.kind)}${event}`
    })

    assert.deepEqual(seen.sort(), ['a1:waterfall', 'h1:emit:llm/models-updated', 'l1:session-list'],
      `三帧各归各流，且转发流只拿到非列表那一类；实际 ${seen.join(', ')}`)

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
