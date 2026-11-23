/**
 * 权限适配器的测试。宿主的目录是假件，按 `PermissionSources` 的形状给。
 *
 * 这一层只剩一件事：**目录原样交出，但 `custom` 摘掉**。切档与当前值都不在这里
 * （前者走命令域，后者走 `permissions` 投影）—— 判据如果还得断言 `select`，说明
 * 那条写路径又回来了。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { permissionPortOver, type PermissionSources } from '../../src/upstream/permission.ts'
import { permissionChannelOver, type HostContext } from '../../src/upstream/faces.ts'
import type { PermissionCatalog, PermissionOption } from '../../src/wire/permission.ts'

// -- helpers -----------------------------------------------------------------

const THREE: readonly PermissionOption[] = [
  { value: 'read-only', name: 'read-only' },
  { value: 'workspace-write', name: 'workspace-write' },
  { value: 'danger-full-access', name: 'danger-full-access', description: 'Full access without prompts.' },
]

const CATALOG: PermissionCatalog = {
  options: THREE,
  defaultOptions: THREE,
  defaultPreset: 'workspace-write',
}

function fakeSources(overrides: Partial<PermissionSources> = {}): PermissionSources {
  return { catalog: () => CATALOG, ...overrides }
}

// -- 读 ----------------------------------------------------------------------

test('catalog forwards the host catalog verbatim — three keys, no current value', async () => {
  const port = permissionPortOver(fakeSources())
  assert.deepEqual(await port.catalog(), {
    options: [
      { value: 'read-only', name: 'read-only' },
      { value: 'workspace-write', name: 'workspace-write' },
      { value: 'danger-full-access', name: 'danger-full-access', description: 'Full access without prompts.' },
    ],
    defaultOptions: [
      { value: 'read-only', name: 'read-only' },
      { value: 'workspace-write', name: 'workspace-write' },
      { value: 'danger-full-access', name: 'danger-full-access', description: 'Full access without prompts.' },
    ],
    defaultPreset: 'workspace-write',
  }, '`current` 不在这条应答里：它住在 `permissions` 投影里，两处各一份就会分叉')
})

test('catalog never forwards "custom" — it is a display state, not a switch target', async () => {
  // 上游今天不把 custom 放进目录，这条挡的是它哪天变了：custom 出现在可点项里，
  // 用户点下去什么都不会发生，而界面看起来像是能切。
  const withCustom: PermissionCatalog = {
    ...CATALOG,
    options: [...THREE, { value: 'custom', name: 'Custom' }],
    defaultOptions: [...THREE, { value: 'custom', name: 'Custom' }],
  }
  const port = permissionPortOver(fakeSources({ catalog: () => withCustom }))
  const catalog = await port.catalog()
  assert.deepEqual(catalog?.options.map(option => option.value),
    ['read-only', 'workspace-write', 'danger-full-access'])
  assert.deepEqual(catalog?.defaultOptions.map(option => option.value),
    ['read-only', 'workspace-write', 'danger-full-access'], '两格都要过这道滤，只滤一处就是漏')
})

// -- 装配层：服务缺席不是错误 ------------------------------------------------

/** 只提供 `reflect.get` 的假上下文 —— 取不到的宿主服务由参数决定。 */
function fakeContext(services: Record<string, unknown>): HostContext {
  return { reflect: { get: (name: string) => services[name] } } as unknown as HostContext
}

test('permissionChannelOver: no presets service reads as an absent capability', async () => {
  const port = permissionChannelOver(fakeContext({}))
  // 三键一起缺席 —— 手机据此不画那一格。空数组是另一件事（服务在、没配）。
  assert.equal(await port.catalog(), undefined)
})

test('permissionChannelOver: a presets service without a readable catalog also counts as absent', async () => {
  const port = permissionChannelOver(fakeContext({ permissionPresets: {} }))
  assert.equal(await port.catalog(), undefined)
})

test('permissionChannelOver: a present service is resolved lazily and served verbatim', async () => {
  const port = permissionChannelOver(fakeContext({ permissionPresets: { catalog: () => CATALOG } }))
  assert.deepEqual(await port.catalog(), CATALOG,
    '晚就绪的插件也该在下一次调用时接上（懒解析）')
})
