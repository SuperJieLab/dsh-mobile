/**
 * `workspace-delete` 经 `handle` 的分派。
 *
 * 这一层守三件在适配层看不到的事：**载荷畸形时一次宿主调用都不发生**、宿主失败折成
 * `internal-error`，以及应答**不多给**客户端一个它不消费的格子。
 *
 * 「删一个已经没有的算成功」不在这里测 —— 那条住在适配层（`deleteWorkspaceIn` 吞
 * `workspace/not-found`），在协议层用假端口复现它只会测到假端口自己的行为。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WorkspacePort } from '../../src/ports/workspace.ts'

const PORT: SessionPort = { list: async () => ({ items: [] }), page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

/** 一个只会 `delete` 的工作空间端口，并记下它被问过的 id。 */
function workspacePort(remove: (id: string) => Promise<void>): {
  port: WorkspacePort
  asked: string[]
} {
  const asked: string[] = []
  return {
    asked,
    port: {
      // 这组用例不读列表；分组链路的判据在 `tests/remote/workspace-stream.test.ts`。
      create: async () => { throw new Error('create is not expected in a delete test') },
      delete: async (workspaceId) => {
        asked.push(workspaceId)
        await remove(workspaceId)
      },
    },
  }
}

/** 发一条 `workspace-delete`（宿主的 `request` 容器就是线上那一层）。 */
function ask(workspaceId: unknown, port: WorkspacePort | undefined) {
  return invoke('workspace/delete', { request: { workspaceId } }, { session: PORT, workspace: port }, Date.now)
}

interface Answer {
  ok: boolean
  error?: { code?: string }
}

test('workspace-delete hands the id straight to the host', async () => {
  const { port, asked } = workspacePort(async () => undefined)

  const answer = await ask('w-a', port) as Answer

  assert.deepEqual(asked, ['w-a'], '删的就是被点的那一个')
  assert.equal(answer.ok, true)
})

test('a malformed id is refused before the host is asked', async () => {
  for (const workspaceId of ['', 42, null, {}, undefined]) {
    const { port, asked } = workspacePort(async () => undefined)

    const answer = await ask(workspaceId, port) as Answer

    assert.equal(answer.ok, false, `${JSON.stringify(workspaceId)} 该被拒`)
    assert.equal(answer.error?.code, 'invalid-request', '写路径从严')
    assert.deepEqual(asked, [], '畸形载荷不得触达宿主')
  }
})

test('a payload without the request container is refused, not read as a malformed id', async () => {
  const { port, asked } = workspacePort(async () => undefined)

  const answer = await invoke('workspace/delete', { workspaceId: 'w-a' }, { session: PORT, workspace: port }, Date.now) as Answer

  assert.equal(answer.ok, false, '少一层容器的客户端是旧客户端 —— 它的 id 根本没送到')
  assert.equal(answer.error?.code, 'invalid-request')
  assert.deepEqual(asked, [], '畸形载荷不得触达宿主')
})

test('a host failure folds into internal-error', async () => {
  const { port } = workspacePort(async () => { throw new Error('registry is on fire') })

  const answer = await ask('w-a', port) as Answer

  assert.equal(answer.ok, false)
  assert.equal(answer.error?.code, 'internal-error', '宿主失败不得变成 ok')
})

test('workspace-delete refuses when the channel is not wired', async () => {
  const answer = await ask('w-a', undefined) as Answer

  assert.equal(answer.ok, false)
  assert.equal(answer.error?.code, 'internal-error',
    '仅只读装配会缺这个端口；拒答而不是崩')
})

test('the answer carries no flag the client would not read', async () => {
  const { port } = workspacePort(async () => undefined)

  const answer = await ask('w-a', port) as Record<string, unknown>

  // 先钉住这是一次**成功**的应答：失败应答同样没有 `deleted`，不钉的话这条在任何错误上都成立。
  assert.equal(answer.ok, true, '先确认这一次确实成功了')
  assert.equal('deleted' in answer, false,
    '两种结局（真删了 / 本来就没有）客户端要做的事完全一样 —— 多一格就要多一条「拿它做什么」')
})
