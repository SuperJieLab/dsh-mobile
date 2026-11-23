/**
 * `workspace/create` 与 `directoryPicker/list` 经端点表的分派。
 *
 * 守两件在适配层看不到的事：**载荷畸形时一次宿主调用都不发生**（判型先于副作用），
 * 以及应答原样答回去 —— 少一格，手机那边会把它读成失败，而宿主其实已经做了。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WorkspacePort, WorkspaceView } from '../../src/ports/workspace.ts'
import type { DirectoryPort } from '../../src/ports/directory.ts'

const PORT: SessionPort = { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

const VIEW: WorkspaceView = {
  workspaceId: 'w-1',
  path: '/Users/x/记账 App',
  title: '记账 App',
  sessionIds: [],
  createdAt: '2026-11-23T00:00:00.000Z',
  updatedAt: '2026-11-23T00:00:00.000Z',
}

/** 一个只会 `create` 的工作空间端口，并记下它被问过的路径。 */
function workspacePort(
  make: (path: string) => Promise<{ workspace: WorkspaceView; created: boolean }>,
): { port: WorkspacePort; asked: string[] } {
  const asked: string[] = []
  return {
    asked,
    port: {
      // 这组用例不读列表；分组链路的判据在 `list-workspaces.test.ts`。
      delete: async () => { throw new Error('workspace-create must not delete anything') },
      create: async (path) => {
        asked.push(path)
        return await make(path)
      },
    },
  }
}

async function ask(args: unknown, port: WorkspacePort | undefined) {
  const result = await invoke('workspace/create', args as Record<string, unknown>, { session: PORT, workspace: port })
  return result.ok ? { ok: true, ...result.value as object } : { ok: false, error: result.error }
}

test('workspace/create answers the host value verbatim', async () => {
  const { port, asked } = workspacePort(async () => ({ workspace: VIEW, created: true }))

  const answer = await ask({ request: { path: '/Users/x/记账 App' } }, port) as {
    ok: boolean; workspace?: WorkspaceView; created?: boolean
  }

  assert.deepEqual(asked, ['/Users/x/记账 App'], '路径原样交给宿主')
  assert.equal(answer.ok, true)
  assert.deepEqual(answer.workspace, VIEW, '七个字段原样 —— 网关不裁')
  assert.equal(answer.created, true,
    'created 必须上线：手机靠它区分「建好了」与「已经有了」，缺了它两端会把一次成功读成失败')
})

test('a malformed path is refused before the host is called', async () => {
  for (const args of [
    {},
    { path: '/Users/x' },
    { request: {} },
    { request: { path: '' } },
    { request: { path: '   ' } },
    { request: { path: 42 } },
  ]) {
    const { port, asked } = workspacePort(async () => ({ workspace: VIEW, created: true }))

    const answer = await ask(args, port) as { ok: boolean; error?: { code?: string } }

    assert.equal(answer.ok, false, `${JSON.stringify(args)} 该被拒`)
    assert.equal(answer.error?.code, 'invalid-request')
    assert.deepEqual(asked, [], '畸形载荷一次宿主调用都不该发生')
  }
})

test('a host refusal folds into internal-error', async () => {
  const { port } = workspacePort(async () => { throw new Error('workspace create exploded') })

  const answer = await ask({ request: { path: '/Users/x' } }, port) as { ok: boolean; error?: { code?: string } }

  assert.equal(answer.ok, false)
  assert.equal(answer.error?.code, 'internal-error', '宿主失败不得变成 ok')
})

test('workspace/create refuses when the channel is not wired', async () => {
  const answer = await ask({ request: { path: '/Users/x' } }, undefined) as { ok: boolean; error?: { code?: string } }

  assert.equal(answer.ok, false)
  assert.equal(answer.error?.code, 'internal-error', '仅只读装配会缺这个端口；拒答而不是崩')
})

// -- directoryPicker/list ----------------------------------------------------

function directoryPort(): { port: DirectoryPort; asked: (string | undefined)[] } {
  const asked: (string | undefined)[] = []
  return {
    asked,
    port: {
      list: async (path) => {
        asked.push(path)
        return {
          path: path ?? '/Users/x',
          home: '/Users/x',
          crumbs: [{ name: '/', path: '/', hidden: false }],
          entries: [{ name: 'proj', path: '/Users/x/proj', hidden: false }],
          truncated: false,
        }
      },
    },
  }
}

test('directoryPicker/list forwards an absent path as absent, not as an empty string', async () => {
  const { port, asked } = directoryPort()

  const result = await invoke('directoryPicker/list', {}, { session: PORT, directory: port })
  assert.equal(result.ok, true)
  assert.deepEqual(asked, [undefined], '缺省就是缺省 —— 宿主据此列 home')
  assert.deepEqual(result.ok ? result.value : undefined, {
    path: '/Users/x', home: '/Users/x',
    crumbs: [{ name: '/', path: '/', hidden: false }],
    entries: [{ name: 'proj', path: '/Users/x/proj', hidden: false }],
    truncated: false,
  }, '五个键原样 —— 网关不裁行、不归一化路径')
})

test('directoryPicker/list forwards a path verbatim and refuses an empty one', async () => {
  const { port, asked } = directoryPort()

  const ok = await invoke('directoryPicker/list', { path: '/Users/x/proj' }, { session: PORT, directory: port })
  assert.equal(ok.ok, true)
  assert.deepEqual(asked, ['/Users/x/proj'])

  for (const path of ['', 42, null]) {
    const bad = await invoke('directoryPicker/list', { path }, { session: PORT, directory: port })
    assert.equal(bad.ok, false, JSON.stringify(path))
    assert.equal(bad.ok ? '' : bad.error.code, 'invalid-request')
  }
  assert.deepEqual(asked, ['/Users/x/proj'], '畸形那三次都没到宿主')
})

test('directoryPicker/list refuses when the channel is not wired', async () => {
  const result = await invoke('directoryPicker/list', {}, { session: PORT })
  assert.equal(result.ok, false)
  assert.equal(result.ok ? '' : result.error.code, 'internal-error')
})
