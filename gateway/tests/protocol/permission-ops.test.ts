/**
 * 权限目录经 `handle` 的分派与应答形状。权限端口是假件：无网络、无 DSH 运行时。
 *
 * **这条应答里只有目录**。当前值是会话级的事实，住在 `permissions` 投影里（随
 * `session/control` 到客户端）；把它塞回目录应答，就会出现「目录是新的、当前值是旧的」
 * 而没人分得清——判据把这条按 deepEqual 钉死：多一格 `current` 就红。
 *
 * **切档不在这里**：走 `commands/execute` 的 `/permission <preset>`。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, valueOf } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { PermissionPort } from '../../src/ports/permission.ts'
import type { PermissionCatalog, PermissionOption } from '../../src/wire/permission.ts'

// -- helpers -----------------------------------------------------------------

const PORT: SessionPort = { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

const OPTIONS: readonly PermissionOption[] = [
  { value: 'read-only', name: 'read-only' },
  { value: 'workspace-write', name: 'workspace-write' },
  { value: 'danger-full-access', name: 'danger-full-access' },
]

const CATALOG: PermissionCatalog = {
  options: [...OPTIONS],
  defaultOptions: [...OPTIONS],
  defaultPreset: 'workspace-write',
}

/** 假权限端口：只有目录。切档已经不在这条域里。传 `null` 表示这个装配没有权限服务。 */
function fakePermission(catalog: PermissionCatalog | null = CATALOG): PermissionPort {
  return { catalog: async () => (catalog === null ? undefined : catalog) }
}

function ask(permission?: PermissionPort) {
  return invoke('permissionPresets/catalog', {}, { session: PORT, permission })
}

// -- permissionPresets/catalog -----------------------------------------------

test('permissionPresets/catalog: the three catalog keys come back verbatim', async () => {
  const reply = await ask(fakePermission())
  // 整份 deepEqual：多一格 `current`、`sandbox` 或 `approval` 就红 ——
  // 那几格一旦发出去，客户端就会自己折叠出第二份判定，而宿主才是唯一出处。
  assert.deepEqual(reply, { ok: true, value: CATALOG })
})

test('permissionPresets/catalog: an empty catalog is a success — the service is there, nothing configured', async () => {
  const empty: PermissionCatalog = { options: [], defaultOptions: [], defaultPreset: 'read-only' }
  const reply = await ask(fakePermission(empty))
  assert.equal(reply.ok, true)
  assert.deepEqual(valueOf(reply), empty)
})

test('permissionPresets/catalog: a service that is not there answers an empty value, not a guess', async () => {
  // 三键一起缺席：客户端据「没有 options」不画那一格。空数组是另一件事（服务在、没配）。
  const reply = await ask(fakePermission(null))
  assert.deepEqual(reply, { ok: true, value: {} })
})

test('permissionPresets/catalog: no arguments are required and extra ones are ignored', async () => {
  // 一元的 args 宽松：这条端点一个参数都不要。给一个多余的键不该改变结果。
  const reply = await invoke('permissionPresets/catalog', { sessionId: 'ignored' },
    { session: PORT, permission: fakePermission() })
  assert.deepEqual(reply, { ok: true, value: CATALOG })
})

test('permission ops: an unwired port is internal-error', async () => {
  const reply = await ask()
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'internal-error')
})

// -- 旧的两条已经退场 --------------------------------------------------------

test('the old permission endpoints are gone', async () => {
  // 这两个名字写在这里是**断言的对象**，不是还在用的端点：判据要能证明它们已被摘掉，
  // 就不得不写出它们。HTTP 那一层另有一条（`http-routing.test.ts`）测同一件事的 404 形态。
  for (const endpoint of ['mobile/permissionCatalog', 'mobile/permissionSelect']) { // terms-ok: 退场端点名，本行是断言对象
    const reply = await invoke(endpoint, {}, { session: PORT, permission: fakePermission() })
    assert.equal(reply.ok, false, endpoint)
    if (!reply.ok) assert.equal(reply.error.code, 'unknown-endpoint', endpoint)
  }
})
