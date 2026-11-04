/**
 * 权限适配器的测试。宿主的三次取数与一次落地是假件，按 `PermissionSources` 的形状给 ——
 * 适配器不认识宿主服务本身，所以这里不需要五个假服务。
 *
 * 这里钉的四件事：**未知预设到不了命令**、**命令行恰好是 `/permission <preset>`**、
 * **三种结局各自映射到不同的码**、**`custom` 永不转发**。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { permissionPortOver, type CommandCall, type PermissionSources } from '../../src/upstream/permission.ts'
import { permissionChannelOver, type HostContext } from '../../src/upstream/faces.ts'
import type { PermissionOption } from '../../src/wire/permission.ts'

// -- helpers -----------------------------------------------------------------

const THREE: readonly PermissionOption[] = [
  { value: 'read-only', name: 'read-only' },
  { value: 'workspace-write', name: 'workspace-write' },
  { value: 'danger-full-access', name: 'danger-full-access', description: 'Full access without prompts.' },
]

/** 假取数：记下每一次交给宿主的命令行，便于断言「有没有真的到命令」。 */
function fakeSources(overrides: Partial<PermissionSources> = {}): PermissionSources & {
  lines: string[]
} {
  const lines: string[] = []
  return {
    lines,
    options: () => THREE,
    currentOf: () => 'workspace-write',
    async execute(_sessionId, line) {
      lines.push(line)
      return { kind: 'accepted', commandId: 'cmd-1' }
    },
    ...overrides,
  }
}

// -- 读 ----------------------------------------------------------------------

test('catalog forwards the host options and the projected current value', async () => {
  const port = permissionPortOver(fakeSources())
  assert.deepEqual(await port.catalog('s'), {
    current: 'workspace-write',
    options: [
      { value: 'read-only', name: 'read-only' },
      { value: 'workspace-write', name: 'workspace-write' },
      { value: 'danger-full-access', name: 'danger-full-access', description: 'Full access without prompts.' },
    ],
  })
})

test('catalog omits current when the host cannot tell — it never invents a default', async () => {
  const port = permissionPortOver(fakeSources({ currentOf: () => undefined }))
  const view = await port.catalog('gone')
  assert.equal('current' in view, false)
  assert.equal(view.options?.length, 3)
})

test('catalog never forwards "custom" — it is a display state, not a switch target', async () => {
  // 上游今天不把 custom 放进目录，这条挡的是它哪天变了：custom 出现在可点项里，
  // 用户点下去什么都不会发生，而界面看起来像是能切。
  const port = permissionPortOver(fakeSources({
    options: () => [...THREE, { value: 'custom', name: 'Custom' }],
  }))
  const view = await port.catalog('s')
  assert.deepEqual(view.options?.map(option => option.value),
    ['read-only', 'workspace-write', 'danger-full-access'])
})

// -- 写 ----------------------------------------------------------------------

test('select refuses a preset that is not in the catalog without touching the host', async () => {
  const sources = fakeSources()
  const port = permissionPortOver(sources)
  const outcome = await port.select('s', 'not-a-preset')
  assert.deepEqual(outcome, {
    ok: false,
    code: 'unknown-preset',
    message: 'no preset "not-a-preset" in this deployment\'s permission catalog',
  })
  // 少了目录校验，这个 op 就成了「发一行字」的通道 —— 客户端传什么都会落到命令行解析上。
  assert.deepEqual(sources.lines, [])
})

test('select hands over exactly "/permission <preset>" and reports the value it read back', async () => {
  const sources = fakeSources({ currentOf: () => 'danger-full-access' })
  const port = permissionPortOver(sources)
  assert.deepEqual(await port.select('s', 'danger-full-access'), { ok: true, current: 'danger-full-access' })
  assert.deepEqual(sources.lines, ['/permission danger-full-access'])
})

test('select maps a vanished agent onto unknown-session, not onto a bad name', async () => {
  const sources = fakeSources({ execute: async (): Promise<CommandCall> => ({ kind: 'no-agent' }) })
  const port = permissionPortOver(sources)
  const outcome = await port.select('s', 'read-only')
  // 「会话没了」与「这个名字不对」的补救不同：前者等它被打开，后者重拉目录再选。
  assert.deepEqual(outcome, { ok: false, code: 'unknown-session', message: 'no live session "s"' })
})

test('select maps an unparsable line onto unknown-preset — a split catalog is never a success', async () => {
  const sources = fakeSources({ execute: async (): Promise<CommandCall> => ({ kind: 'unparsable' }) })
  const port = permissionPortOver(sources)
  const outcome = await port.select('s', 'read-only')
  assert.equal(outcome.ok, false)
  if (outcome.ok) return
  assert.equal(outcome.code, 'unknown-preset')
  // 报的是那一行原文：目录里明明有这个名字，问题在两边名单已经分叉。
  assert.match(outcome.message, /\/permission read-only/)
})

// -- 装配层：服务缺席不是错误 ------------------------------------------------

/** 只提供 `reflect.get` 的假上下文 —— 取不到的宿主服务由参数决定。 */
function fakeContext(services: Record<string, unknown>): HostContext {
  return {
    reflect: { get: (name: string) => services[name] },
    agents: { get: () => undefined },
    sessions: { get: () => undefined },
    sessionProjections: { snapshot: () => undefined },
  } as unknown as HostContext
}

test('permissionChannelOver: no presets service reads as an absent capability, and writes refuse', async () => {
  const port = permissionChannelOver(fakeContext({}))
  // 读照常应答，只是 options 缺键 —— 手机据此不画那一格。
  assert.deepEqual(await port.catalog('s'), {})
  // 写没得谈：没有预设服务就没有目录可校验，也没有命令可发。
  await assert.rejects(() => port.select('s', 'read-only'), /permission-presets service is not composed/)
})

test('permissionChannelOver: a presets service without a readable catalog also counts as absent', async () => {
  const port = permissionChannelOver(fakeContext({ permissionPresets: {} }))
  assert.deepEqual(await port.catalog('s'), {})
})
