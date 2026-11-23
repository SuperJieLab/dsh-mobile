/**
 * `workspace/follow` 流：七种帧原样透传，取消传到上游。
 *
 * 这条流在网关里**没有判定** —— 组清单、归属、归档与置顶都由宿主算好。所以判据只有两件事：
 * 帧一个字段都没被改（首帧是 `baseline`，其余六种增量各来一条），以及取消真的停到了上游。
 *
 * 与 `session/follow` 的判据分文件：两条流的源、故障域与形状都不同，混在一处会让
 * 「这条断言在测哪条流」需要回头翻代码。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'

import { attachStreamHandler } from '../../src/remote/server.ts'
import type { FollowSource } from '../../src/ports/follow.ts'
import type { WorkspacePort } from '../../src/ports/workspace.ts'
import type { WorkspaceBaseline, WorkspaceFollowFrame, WorkspaceView } from '../../src/wire/workspace-stream.ts'
import { connect, receive, send } from './harness.ts'

/** 一条不参与本文件的会话流 —— 组流与它无关，用到就是判据写错了。 */
const sessionSource: FollowSource = {
  // eslint-disable-next-line require-yield
  async *follow() {
    throw new Error('session/follow is not part of a workspace-stream test')
  },
}

/** 两条写 op 在这组用例里不该被走到。 */
const writeFace = {
  create: async () => { throw new Error('create is not part of a workspace-stream test') },
  delete: async () => { throw new Error('delete is not part of a workspace-stream test') },
}

/** 一条组：字段名与上游 `WorkspaceView` 逐字相同。 */
function view(workspaceId: string, title: string, sessionIds: string[] = []): WorkspaceView {
  return {
    workspaceId,
    path: `/Users/x/${title}`,
    title,
    sessionIds,
    createdAt: '2026-11-20T10:00:00.000Z',
    updatedAt: '2026-11-22T09:00:00.000Z',
  }
}

const BASELINE: WorkspaceBaseline = {
  items: [view('w-1', '记账', ['s-1']), view('w-2', '试验')],
  archivedSessionIds: ['s-9'],
  pinnedSessionIds: ['s-1'],
}

test('workspace/follow: the baseline, then every increment, then end — verbatim', { timeout: 10_000 }, async () => {
  const frames: WorkspaceFollowFrame[] = [
    { type: 'baseline', value: BASELINE },
    { type: 'replace', value: { ...BASELINE, items: [view('w-1', '记账', ['s-1'])] } },
    { type: 'upsert', workspace: view('w-3', '新组', ['s-2']) },
    { type: 'remove', workspaceId: 'w-2' },
    { type: 'order', workspaceIds: ['w-3', 'w-1'] },
    { type: 'archived', archivedSessionIds: ['s-9', 's-10'] },
    { type: 'pinned', pinnedSessionIds: ['s-2'] },
  ]
  const workspace: WorkspacePort = {
    ...writeFace,
    async *follow() {
      for (const frame of frames) yield frame
    },
  }

  const server = createServer()
  attachStreamHandler(server, sessionSource, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) },
    { workspace })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'g1', endpoint: 'workspace/follow', payload: { args: {} } })

    for (const expected of frames) {
      const frame = await receive(socket)
      assert.equal(frame.type, 'item', `${expected.type}: 每一帧都包成 item`)
      assert.equal(frame.streamId, 'g1')
      // **逐字**比较：泵只做帧化，不改名、不裁字段、不补默认值。
      assert.deepEqual(frame.value, expected, `${expected.type}: 帧被改过`)
    }

    const end = await receive(socket)
    assert.deepEqual(end, { type: 'end', streamId: 'g1' }, '源结束之后发 end，不是静默收流')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('workspace/follow: cancel reaches the host and stops this stream only', { timeout: 10_000 }, async () => {
  let signal: AbortSignal | undefined
  const workspace: WorkspacePort = {
    ...writeFace,
    async *follow(abort) {
      signal = abort
      yield { type: 'baseline', value: BASELINE }
      let count = 0
      // 上界只为让失败路径能收场：cancel 没传到时这个循环自己结束，进程不会挂着。
      while (!abort.aborted && count < 100) {
        count += 1
        yield { type: 'upsert', workspace: view(`w-${count}`, `组 ${count}`) }
        await new Promise(resolve => setTimeout(resolve, 5))
      }
    },
  }

  const server = createServer()
  attachStreamHandler(server, sessionSource, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) },
    { workspace })
  server.listen(0)
  let socket: WebSocket | undefined
  try {
    await once(server, 'listening')
    socket = await connect(server)

    send(socket, { type: 'open', streamId: 'g1', endpoint: 'workspace/follow', payload: { args: {} } })
    await receive(socket) // baseline
    await receive(socket) // 第一条 upsert

    let afterCancel = 0
    socket.addEventListener('message', () => { afterCancel += 1 })
    send(socket, { type: 'cancel', streamId: 'g1' })

    for (let i = 0; i < 50 && signal?.aborted !== true; i++) {
      await new Promise(resolve => setTimeout(resolve, 10))
    }
    assert.equal(signal?.aborted, true, 'cancel 必须中止宿主那条流')

    // 「静默是持续的」：只等一次固定时长时，慢机器上「没来得及发」会被读成「已经停了」。
    await new Promise(resolve => setTimeout(resolve, 100))
    const settled = afterCancel
    await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(afterCancel, settled, 'cancel 之后不该再有新帧（源每 5ms 还在产出）')
  } finally {
    socket?.close()
    server.closeAllConnections()
    server.close()
  }
})

test('workspace/follow: a gateway without the workspace face refuses instead of staying silent', { timeout: 10_000 }, async () => {
  const server = createServer()
  // 装配缺这一条：没有 `options.workspace`。拒绝要响 —— 静默的表现是客户端等 45 秒，
  // 而开流超时判的是**整条连接**（所有流一起被关）。
  attachStreamHandler(server, sessionSource, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'g1', endpoint: 'workspace/follow', payload: { args: {} } })

    const frame = await receive(socket)
    assert.equal(frame.type, 'error')
    assert.equal((frame.error as { code?: string }).code, 'internal-error')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('workspace/follow: args must be empty — a session id is not a parameter of this stream', { timeout: 10_000 }, async () => {
  const workspace: WorkspacePort = {
    ...writeFace,
    async *follow() {
      yield { type: 'baseline', value: BASELINE }
    },
  }

  const server = createServer()
  attachStreamHandler(server, sessionSource, { authenticate: () => ({ id: 'test-identity', canAnswer: true }) },
    { workspace })
  server.listen(0)
  try {
    await once(server, 'listening')
    const socket = await connect(server)

    send(socket, { type: 'open', streamId: 'g1', endpoint: 'workspace/follow', payload: { args: { sessionId: 's-1' } } })

    const frame = await receive(socket)
    assert.equal(frame.type, 'error')
    assert.equal((frame.error as { code?: string }).code, 'invalid-args')

    socket.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
