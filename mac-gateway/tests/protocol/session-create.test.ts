/**
 * `session-create` 经 `handle` 的分派：id 原样透出，宿主拒绝时折成 `internal-error`。
 *
 * 这一层只问「分派与折码」：目录取哪、会不会复用空会话都是宿主的事（见
 * `dev/research/new-session.md`），我们只承诺「不自己造 id」与「失败不静默」。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WritePort } from '../../src/ports/write.ts'

const PORT: SessionPort = { list: async () => [], read: async () => undefined, readAll: async () => undefined }

/** 只要一个能答 `createSession` 的写端口；另外两个方法在这一组里不会被走到。 */
function writeReturning(make: () => Promise<string>): WritePort {
  return {
    answerApproval: async () => 'delivered',
    promptSession: async () => 'accepted',
    createSession: make,
  }
}

test('session-create answers the id the host handed back', async () => {
  let calls = 0
  const port = writeReturning(async () => {
    calls += 1
    return 's-test'
  })

  const answer = await handle({ v: 2, op: 'session-create' }, { session: PORT, write: port }, Date.now)

  assert.equal(calls, 1, '一次 op 只该问宿主一次')
  assert.deepEqual(answer, { v: 2, ok: true, sessionId: 's-test' },
    'id 必须是宿主给的那个 —— 网关不许自己造')
})

test('session-create folds a host refusal into internal-error', async () => {
  const port = writeReturning(async () => {
    throw new Error('host said no')
  })

  const answer = await handle({ v: 2, op: 'session-create' }, { session: PORT, write: port }, Date.now)

  assert.equal(answer.ok, false, '宿主拒绝不得变成 ok')
  assert.equal((answer as { error?: { code?: string } }).error?.code, 'internal-error',
    '折成 internal-error：手机那边只看到这一个笼统结论，具体原因在网关日志里')
})

test('session-create refuses when the write channel is not wired', async () => {
  const answer = await handle({ v: 2, op: 'session-create' }, { session: PORT })

  assert.equal(answer.ok, false)
  assert.equal((answer as { error?: { code?: string } }).error?.code, 'internal-error',
    '仅只读装配会缺这个端口；生产必接线，但拒答而不是崩')
})

/** 记下宿主的建会话口收到了什么；两个不该被走到的写方法给桩。 */
function writeRecording(): { port: WritePort; targets: (string | undefined)[] } {
  const targets: (string | undefined)[] = []
  return {
    targets,
    port: {
      answerApproval: async () => 'delivered',
      promptSession: async () => 'accepted',
      createSession: async (workspaceId) => {
        targets.push(workspaceId)
        return 's-test'
      },
    },
  }
}

test('session-create hands the workspace to the host when the request names one', async () => {
  const { port, targets } = writeRecording()

  await handle({ v: 2, op: 'session-create', workspaceId: 'w-a' }, { session: PORT, write: port }, Date.now)

  assert.deepEqual(targets, ['w-a'], '手机点的那个组必须原样传到宿主')
})

test('session-create without a target keeps the host default', async () => {
  const { port, targets } = writeRecording()

  await handle({ v: 2, op: 'session-create' }, { session: PORT, write: port }, Date.now)

  assert.deepEqual(targets, [undefined],
    '不带就是不带 —— 传空串会假装「指定了一个工作空间」，而宿主会用空 cwd 去建会话')
})

test('a malformed workspace target is refused before the host is asked', async () => {
  for (const workspaceId of ['', 42, null, {}]) {
    const { port, targets } = writeRecording()
    const answer = await handle({ v: 2, op: 'session-create', workspaceId }, { session: PORT, write: port }, Date.now)

    assert.equal(answer.ok, false, `${JSON.stringify(workspaceId)} 该被拒`)
    assert.equal((answer as { error?: { code?: string } }).error?.code, 'invalid-request',
      '写载荷从严：畸形不得凭猜测执行')
    assert.deepEqual(targets, [], '畸形载荷不得触达宿主')
  }
})
