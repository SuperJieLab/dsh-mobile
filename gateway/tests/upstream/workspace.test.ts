/**
 * 工作空间快照：组清单与归属表都从注册表来，各自只有一处来源。
 *
 * 这一层只问「注册表的成员表被翻译成了什么」：清单保序、归属逐条对得上。
 * 宿主怎么建那份索引（realpath、符号链接、大小写）是它的事 —— 我们不再实现一遍。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createWorkspaceIn, deleteWorkspaceIn } from '../../src/upstream/workspace.ts'

// -- 注册（幂等） -------------------------------------------------------------

/**
 * 宿主的 `workspaceController` 形状：`create` 对同一条路径幂等，并用 `created` 告诉你
 * 这一次是不是新建的 —— 这一格是控制器给的，注册表本身没有。
 */
function fakeController() {
  const byPath = new Map<string, {
    workspaceId: string; path: string; title: string; sessionIds: readonly string[]
    createdAt: string; updatedAt: string
  }>()
  let serial = 0
  return {
    calls: 0,
    async create(request: { path: string }) {
      this.calls += 1
      const existing = byPath.get(request.path)
      if (existing !== undefined) return { workspace: existing, created: false }
      serial += 1
      const workspace = {
        workspaceId: `w-${serial}`,
        path: request.path,
        title: request.path.split('/').at(-1) ?? request.path,
        sessionIds: [],
        createdAt: '2026-11-23T00:00:00.000Z',
        updatedAt: '2026-11-23T00:00:00.000Z',
      }
      byPath.set(request.path, workspace)
      return { workspace, created: true }
    },
  }
}

test('registering the same path twice reports created once', async () => {
  const controller = fakeController()
  const first = await createWorkspaceIn(controller, '/根/名字')
  const second = await createWorkspaceIn(controller, '/根/名字')

  assert.equal(first.created, true, '第一次是新建')
  assert.equal(second.created, false, '第二次不是 —— 「已存在」不是失败，是幂等')
  assert.equal(second.workspace.workspaceId, first.workspace.workspaceId, '两次给的是同一个工作空间')
  assert.equal(controller.calls, 2, '两次都问控制器：判断「是不是新建」是它的事，不是我们的')
})

test('a brand-new path reports the title the host derived', async () => {
  const made = await createWorkspaceIn(fakeController(), '/根/记账 App')
  assert.equal(made.workspace.title, '记账 App', '标题由宿主从目录名派生，网关不改写')
  assert.equal(made.workspace.path, '/根/记账 App', '路径原样 —— 网关不归一化')
})

// -- 删除（幂等） -------------------------------------------------------------

/**
 * 宿主的删除面：这个 id 还在就删掉，否则抛 `workspace/not-found` ——
 * 上游就是这么做的（`registry.delete` 回 false 时抛）。
 */
function fakeDeleter(known: readonly string[]) {
  const rest = new Set(known)
  return {
    calls: [] as string[],
    async delete(request: { workspaceId: string }) {
      this.calls.push(request.workspaceId)
      if (!rest.delete(request.workspaceId)) {
        throw Object.assign(new Error(`Workspace "${request.workspaceId}" not found`), {
          isDSHRemoteError: true,
          code: 'workspace/not-found',
        })
      }
      return { deleted: true as const }
    },
  }
}

test('deleting a workspace that is there calls straight through', async () => {
  const controller = fakeDeleter(['w-a'])

  await deleteWorkspaceIn(controller, 'w-a')

  assert.deepEqual(controller.calls, ['w-a'], '删的就是被点的那一个')
})

test('deleting a workspace that is already gone is not a failure', async () => {
  const controller = fakeDeleter([])

  await deleteWorkspaceIn(controller, 'w-gone')

  assert.deepEqual(controller.calls, ['w-gone'],
    '仍然问了宿主一次 —— 不凭本地记忆跳过它，那会让「另一端刚删掉」表现成另一种结局')
})

test('a real host failure is not swallowed', async () => {
  const controller = {
    async delete(): Promise<{ deleted: true }> { throw new Error('disk is on fire') },
  }

  await assert.rejects(() => deleteWorkspaceIn(controller, 'w-a'), /disk is on fire/,
    '只有明确的 not-found 才吞；别的故障必须冒泡成 internal-error')
})
