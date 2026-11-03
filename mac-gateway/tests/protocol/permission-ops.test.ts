/**
 * 两条权限 op 经 `handle` 的分派与应答形状。权限端口是假件：无网络、无 DSH 运行时。
 *
 * 分派与处理器在 `protocol/rpc.ts`；载荷解析在 `wire/permission.ts`；目录怎么读、
 * 切换怎么落到命令上在 `upstream/permission.ts`，另有其测试。
 *
 * 这里钉的三件事最容易被写错：**应答里不带 knob**（带了客户端就会自己折叠出第二份
 * 判定）、**`current` 缺席不等于默认档**、**端口缺席与权限服务缺席是两件事**。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { PermissionPort } from '../../src/ports/permission.ts'
import type { PermissionOption } from '../../src/wire/permission.ts'

// -- helpers -----------------------------------------------------------------

const PORT: SessionPort = { list: async () => [], read: async () => undefined, readAll: async () => undefined }

const OPTIONS: readonly PermissionOption[] = [
  { value: 'read-only', name: 'read-only' },
  { value: 'workspace-write', name: 'workspace-write' },
  { value: 'danger-full-access', name: 'danger-full-access' },
]

/** 假权限端口：记下每次调用的实参，便于断言「有没有真的到端口」。 */
function fakePermission(overrides: Partial<PermissionPort> = {}): PermissionPort & {
  selects: { sessionId: string; preset: string }[]
} {
  const selects: { sessionId: string; preset: string }[] = []
  return {
    selects,
    async catalog() {
      return { current: 'workspace-write', options: OPTIONS }
    },
    async select(sessionId, preset) {
      selects.push({ sessionId, preset })
      return { ok: true, current: preset }
    },
    ...overrides,
  }
}

/** 只给权限端口的一条消息 —— 其余七个端口一律不给（它们的 op 与本文件无关）。 */
function ask(message: Record<string, unknown>, permission?: PermissionPort) {
  return handle(message, PORT, undefined, undefined, undefined, undefined, undefined, undefined, permission)
}

// -- permission-catalog ------------------------------------------------------

test('permission-catalog: the current value and the catalog come back verbatim', async () => {
  const reply = await ask({ v: 2, op: 'permission-catalog', sessionId: 's' }, fakePermission())
  // 整份 deepEqual，不是逐字段：多一个 `sandbox` 或 `approval` 字段就红 ——
  // 那两个 knob 一旦发出去，客户端就能自己折叠出预设，而宿主才是折叠的唯一出处。
  assert.deepEqual(reply, {
    v: 2,
    ok: true,
    current: 'workspace-write',
    options: [
      { value: 'read-only', name: 'read-only' },
      { value: 'workspace-write', name: 'workspace-write' },
      { value: 'danger-full-access', name: 'danger-full-access' },
    ],
  })
})

test('permission-catalog: an unknown current value omits the key instead of guessing a default', async () => {
  const permission = fakePermission({ catalog: async () => ({ options: OPTIONS }) })
  const reply = await ask({ v: 2, op: 'permission-catalog', sessionId: 's' }, permission)
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  // 缺键而不是 null 或默认档：客户端据此显示 `--`，而补一个默认档会与 Web UI 显示的分叉。
  assert.equal('current' in reply, false)
  assert.deepEqual(reply.options, [...OPTIONS])
})

test('permission-catalog: an empty catalog still answers ok — that is not a missing service', async () => {
  const permission = fakePermission({ catalog: async () => ({ current: 'custom', options: [] }) })
  const reply = await ask({ v: 2, op: 'permission-catalog', sessionId: 's' }, permission)
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  // 空数组 = 服务在、一项都没配（客户端画一个点不开的格子）；
  // 服务缺席是 `options` 整个缺键。两者混成一种，客户端就分不出该不该画这一格。
  assert.deepEqual(reply.options, [])
  assert.equal(reply.current, 'custom')
})

test('permission-catalog: a missing session id is unknown-session, not an empty view', async () => {
  const reply = await ask({ v: 2, op: 'permission-catalog' }, fakePermission())
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'unknown-session')
})

// -- permission-select -------------------------------------------------------

test('permission-select: the preset name reaches the port exactly once', async () => {
  const permission = fakePermission()
  const reply = await ask(
    { v: 2, op: 'permission-select', sessionId: 's', preset: 'danger-full-access' }, permission,
  )
  assert.deepEqual(permission.selects, [{ sessionId: 's', preset: 'danger-full-access' }])
  // 回包里的值是受理后重读投影拿到的那个，不是把发出去的那份当答案。
  assert.deepEqual(reply, { v: 2, ok: true, current: 'danger-full-access' })
})

test('permission-select: a malformed payload is invalid-request and never reaches the port', async () => {
  for (const bad of [
    {},
    { sessionId: 's' },
    { preset: 'read-only' },
    { sessionId: '', preset: 'read-only' },
    { sessionId: 's', preset: '' },
    { sessionId: 's', preset: 7 },
  ]) {
    const permission = fakePermission()
    const reply = await ask({ v: 2, op: 'permission-select', ...bad }, permission)
    assert.equal(reply.ok, false, JSON.stringify(bad))
    if (!reply.ok) assert.equal(reply.error.code, 'invalid-request', JSON.stringify(bad))
    assert.deepEqual(permission.selects, [], `畸形载荷绝不进端口：${JSON.stringify(bad)}`)
  }
})

test('permission-select: a refusal keeps the upstream code and its own words', async () => {
  const permission = fakePermission({
    select: async () => ({ ok: false, code: 'unknown-preset', message: 'no preset "nope" in this catalog' }),
  })
  const reply = await ask({ v: 2, op: 'permission-select', sessionId: 's', preset: 'nope' }, permission)
  assert.deepEqual(reply, {
    v: 2,
    ok: false,
    error: { code: 'unknown-preset', message: 'no preset "nope" in this catalog' },
  })
})

test('permission-select: a session without a live agent is unknown-session, not a silent success', async () => {
  const permission = fakePermission({
    select: async () => ({ ok: false, code: 'unknown-session', message: 'no live session "gone"' }),
  })
  const reply = await ask({ v: 2, op: 'permission-select', sessionId: 'gone', preset: 'read-only' }, permission)
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'unknown-session')
})

// -- 端口缺席 ----------------------------------------------------------------

test('permission ops: an unwired port is internal-error on both', async () => {
  for (const message of [
    { v: 2, op: 'permission-catalog', sessionId: 's' },
    { v: 2, op: 'permission-select', sessionId: 's', preset: 'read-only' },
  ]) {
    const reply = await ask(message)
    assert.equal(reply.ok, false, JSON.stringify(message))
    if (!reply.ok) assert.equal(reply.error.code, 'internal-error')
  }
})
