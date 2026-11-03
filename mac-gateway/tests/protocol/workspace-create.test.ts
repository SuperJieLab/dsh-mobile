/**
 * `workspace-create` 经 `handle` 的分派。
 *
 * 这一层守两件在适配层看不到的事：**名字不合法时一次文件系统调用都不发生**（判型先于副作用），
 * 以及应答把宿主给的三格原样答回去 —— 少一格，手机那边会把它读成「建失败」，而 Mac 上其实
 * 已经建好了。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WorkspacePort } from '../../src/ports/workspace.ts'

const PORT: SessionPort = { list: async () => [], read: async () => undefined, readAll: async () => undefined }

/** 一个只会 `create` 的工作空间端口，并记下它被问过的名字。 */
function workspacePort(
  make: (name: string) => Promise<{ workspaceId: string; title: string; created: boolean }>,
): { port: WorkspacePort; asked: string[] } {
  const asked: string[] = []
  return {
    asked,
    port: {
      // 这组用例不读列表；分组链路的判据在 `list-workspaces.test.ts`。
      snapshot: () => ({ rows: [], owners: new Map() }),
      // 删除在本文件里用不到，走到就是编错了。
      delete: async () => { throw new Error('workspace-create must not delete anything') },
      create: async (name) => {
        asked.push(name)
        return await make(name)
      },
    },
  }
}

/** 发一条 `workspace-create`。端口按位置追加在 `handle` 的末尾。 */
function ask(name: unknown, port: WorkspacePort | undefined) {
  return handle({ v: 2, op: 'workspace-create', name }, { session: PORT, workspace: port }, Date.now)
}

interface Answer {
  ok: boolean
  workspaceId?: string
  title?: string
  created?: boolean
  error?: { code?: string }
}

test('workspace-create answers the three cells the host gave back', async () => {
  const { port, asked } = workspacePort(async name => ({
    workspaceId: 'w-new', title: name, created: true,
  }))

  const answer = await ask('  记账  ', port) as Answer

  assert.deepEqual(asked, ['记账'], '名字要先 trim 再往下走')
  assert.equal(answer.ok, true)
  assert.equal(answer.workspaceId, 'w-new')
  assert.equal(answer.title, '记账')
  assert.equal(answer.created, true,
    'created 必须上线：手机靠它区分「建好了」与「已经有了」，缺了它两端会把一次成功读成失败')
})

test('an invalid name is refused before anything touches the filesystem', async () => {
  for (const name of ['', '   ', 'a/b', 'a\\b', '.', '..', 42, undefined]) {
    const { port, asked } = workspacePort(async () => ({ workspaceId: 'w', title: 'w', created: true }))

    const answer = await ask(name, port) as Answer

    assert.equal(answer.ok, false, `${JSON.stringify(name)} 该被拒`)
    assert.equal(answer.error?.code, 'invalid-request')
    assert.deepEqual(asked, [],
      '非法名字一个文件系统调用都不该发生 —— 靠服务端拒绝兜住等于让建目录先跑一遍')
  }
})

test('a host refusal folds into internal-error', async () => {
  const { port } = workspacePort(async () => { throw new Error('mkdir exploded') })

  const answer = await ask('好的名字', port) as Answer

  assert.equal(answer.ok, false)
  assert.equal(answer.error?.code, 'internal-error', '宿主失败不得变成 ok')
})

test('workspace-create refuses when the channel is not wired', async () => {
  const answer = await ask('任意名字', undefined) as Answer

  assert.equal(answer.ok, false)
  assert.equal(answer.error?.code, 'internal-error',
    '仅只读装配会缺这个端口；拒答而不是崩')
})
