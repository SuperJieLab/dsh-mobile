/**
 * 两条模型 op 经分派层的应答形状与请求容器 —— 以及目录**转发不加工**这条承诺。
 *
 * 分派与被测符号：两条 op 在 `protocol/rpc.ts`，容器与字段判型在 `wire/model.ts`。
 * 宿主的目录怎么读在 `upstream/faces.ts` 的 `modelChannelOver`（那里只转发，不再拼形状），
 * 装配那一行由 `tests/upstream/faces.test.ts` 守。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, valueOf } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import { modelSelectRequestOf } from '../../src/wire/model.ts'
import type { ModelPort } from '../../src/ports/model.ts'

// -- helpers -----------------------------------------------------------------

const PORT: SessionPort = {
  list: async () => ({ items: [] }),
  read: async () => undefined,
  readAll: async () => undefined,
}

/**
 * 上游 `ModelCatalog` 的逐字形状 —— 四个键，一个不多一个不少。
 *
 * 判据是「键集合相等」而不是「四个字段各自对」：裁字段的改法（比如再把
 * `routableProviders` 剥掉）会让前三条断言全部照常通过，只有键集合会红。
 */
const CATALOG = {
  default: { provider: 'deepseek', model: 'deepseek-chat' },
  routableProviders: ['deepseek'],
  groups: [
    {
      id: 'deepseek',
      name: 'DeepSeek',
      models: [{ id: 'deepseek-chat', name: 'DeepSeek Chat' }],
    },
  ],
  failures: [{ id: 'broken', name: 'Broken', message: 'no credentials' }],
}

/** A fake model port serving the catalog above. */
function fakeModel(): ModelPort {
  return {
    catalog: async () => CATALOG,
    select: async () => ({ ok: true, selected: { provider: 'deepseek', model: 'deepseek-chat' } }),
  }
}

// -- model-catalog: 转发不加工 ------------------------------------------------

test('model-catalog: the value is the host catalog verbatim — key set included', async () => {
  const reply = await invoke('session/modelCatalog', {}, { session: PORT, model: fakeModel() })
  const body = valueOf<Record<string, unknown>>(reply)
  assert.deepEqual(body, CATALOG, '目录逐字透传：网关不改名、不裁字段、不补默认')
  assert.deepEqual(
    Object.keys(body).sort(),
    ['default', 'failures', 'groups', 'routableProviders'],
    '键集合等于上游 `ModelCatalog` —— 少一个就是被裁过',
  )
})

test('model-catalog: a model\'s reasoning levels ride along untouched', async () => {
  const reasoning = {
    efforts: [{ id: 'low', name: '低' }, { id: 'high', name: '高', description: '想得久一点' }],
    defaultEffort: 'high',
  }
  const withLevels = {
    ...CATALOG,
    groups: [{ ...CATALOG.groups[0], models: [{ id: 'deepseek-chat', name: 'DeepSeek Chat', reasoning }] }],
  }
  const reply = await invoke('session/modelCatalog', {}, {
    session: PORT,
    model: { ...fakeModel(), catalog: async () => withLevels },
  })
  const groups = valueOf<{ groups: typeof withLevels.groups }>(reply).groups
  // 目录是宿主的：`efforts` 与 `defaultEffort` 逐字透传，网关不重排、不补齐。
  assert.deepEqual(groups[0]?.models[0]?.reasoning, reasoning)
})

test('model-catalog: a wedged catalog source is an internal-error envelope, not a crash', async () => {
  const reply = await invoke('session/modelCatalog', {}, {
    session: PORT,
    model: { ...fakeModel(), catalog: async () => { throw new Error('registry exploded') } },
  })
  assert.deepEqual(reply, { ok: false, error: { code: 'internal-error', message: 'registry exploded', details: {} } })
})

// -- model-select -------------------------------------------------------------

test('model-select: well-formed payload parses, reasoningEffort optional', () => {
  assert.deepEqual(
    modelSelectRequestOf({ request: { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' } }),
    { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' },
  )
  assert.deepEqual(
    modelSelectRequestOf({
      request: { sessionId: 's', provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' },
    }),
    { sessionId: 's', provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' },
  )
})

test('model-select: a payload without the request container is malformed, not an empty request', () => {
  // 少一层容器与「发了空对象」是两件事：前者的补救是改客户端，后者才是用户没选。
  assert.equal(modelSelectRequestOf({ sessionId: 's', provider: 'deepseek', model: 'm' }), undefined,
    '平铺的旧形状必须被拒 —— 静默收下等于让旧客户端看起来能用')
  assert.equal(modelSelectRequestOf({ request: [] }), undefined, '容器必须是对象')
  assert.equal(modelSelectRequestOf({ request: null }), undefined)
})

test('model-select: malformed payloads are refused, not normalized (fail-closed)', () => {
  for (const bad of [
    {},
    { request: {} },
    { request: { sessionId: 's', provider: 'deepseek' } },
    { request: { sessionId: 's', model: 'deepseek-chat' } },
    { request: { provider: 'deepseek', model: 'deepseek-chat' } },
    { request: { sessionId: '', provider: 'deepseek', model: 'deepseek-chat' } },
    { request: { sessionId: 's', provider: '', model: 'deepseek-chat' } },
    { request: { sessionId: 's', provider: 'deepseek', model: 7 } },
    { request: { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat', reasoningEffort: '' } },
  ]) {
    assert.equal(modelSelectRequestOf(bad), undefined, JSON.stringify(bad))
  }
})

test('model-select: accepted selection comes back as the normalized choice', async () => {
  const reply = await invoke(
    'session/selectModel',
    { request: { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' } },
    { session: PORT, model: fakeModel() },
  )
  assert.deepEqual(reply, { ok: true, value: { selected: { provider: 'deepseek', model: 'deepseek-chat' } } })
})

test('model-select: upstream refusals come back with their own code', async () => {
  const refusing: ModelPort = {
    ...fakeModel(),
    select: async () => ({
      ok: false,
      code: 'session/model-unavailable',
      message: 'no adapter serves provider "x"',
    }),
  }
  const reply = await invoke(
    'session/selectModel',
    { request: { sessionId: 's', provider: 'x', model: 'm' } },
    { session: PORT, model: refusing },
  )
  assert.deepEqual(reply, {
    ok: false,
    error: { code: 'session/model-unavailable', message: 'no adapter serves provider "x"', details: {} },
  })
})

test('model-select: malformed payload is invalid-request, never reaches the port', async () => {
  const model = fakeModel()
  let asked = false
  const spy: ModelPort = { ...model, select: async (r) => { asked = true; return model.select(r) } }
  const reply = await invoke(
    'session/selectModel',
    { request: { sessionId: 's', provider: '', model: 'm' } },
    { session: PORT, model: spy },
  )
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'invalid-request')
  assert.equal(asked, false)
})
