/**
 * 两条模型 op 经 `handle` 的分派与应答形状。模型端口是假件：无网络、无 DSH 运行时。
 *
 * 分派与被测符号的层次：`handle` 与两条 op 在 `protocol/rpc.ts`；载荷解析在
 * `wire/model.ts`（`modelSelectRequestOf` 的用例也在这里，因为它是这两个 op
 * 唯一被校验的入口）。宿主目录怎么读在 `upstream/model.ts`，另有其测试。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import { modelSelectRequestOf } from '../../src/wire/model.ts'
import type { ModelPort } from '../../src/ports/model.ts'

// -- helpers -----------------------------------------------------------------

const PORT: SessionPort = { list: async () => [], read: async () => undefined, readAll: async () => undefined }

/** A write port the model tests never expect to be called (write wiring is T3's concern). */
const fakeWritePort = (): import('../../src/ports/write.ts').WritePort => ({
  answerApproval: () => Promise.reject(new Error('model tests must not touch the write channel')),
  promptSession: () => Promise.reject(new Error('model tests must not touch the write channel')),
})

/** A catalog the fake port serves; the literal is the independent fact source. */
const CATALOG = {
  default: { provider: 'deepseek', model: 'deepseek-chat' },
  groups: [
    {
      id: 'deepseek',
      name: 'DeepSeek',
      models: [{ id: 'deepseek-chat', name: 'DeepSeek Chat' }],
    },
  ],
  failures: [{ id: 'broken', name: 'Broken', message: 'no credentials' }],
}

/** A fake model port serving the catalog above, or throwing when told to. */
function fakeModel(): ModelPort {
  return {
    catalog: async () => CATALOG,
    select: async () => ({ ok: true, selected: { provider: 'deepseek', model: 'deepseek-chat' } }),
  }
}

// -- model-catalog (G1) ------------------------------------------------------

test('model-catalog: the catalog comes back as the envelope body', async () => {
  const reply = await handle({ v: 2, op: 'model-catalog' }, PORT, undefined, undefined, undefined, fakeModel())
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  assert.deepEqual(reply.default, { provider: 'deepseek', model: 'deepseek-chat' })
  assert.deepEqual(reply.groups, CATALOG.groups)
  assert.deepEqual(reply.failures, CATALOG.failures)
})

test('model-catalog: upstream default absent means the field is absent', async () => {
  const model = fakeModel()
  const bare = { ...CATALOG, default: undefined }
  const reply = await handle({ v: 2, op: 'model-catalog' }, PORT, undefined, undefined, undefined, {
    ...model,
    catalog: async () => bare,
  })
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  assert.equal('default' in reply, false)
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
  const reply = await handle({ v: 2, op: 'model-catalog' }, PORT, undefined, undefined, undefined, {
    ...fakeModel(),
    catalog: async () => withLevels,
  })
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  const groups = reply.groups as typeof withLevels.groups
  // 目录是宿主的：`efforts` 与 `defaultEffort` 逐字透传，网关不重排、不补齐。
  assert.deepEqual(groups[0]?.models[0]?.reasoning, reasoning)
})

// -- model-select (决定 3 / G1 的写半边) -------------------------------------

test('model-select: well-formed payload parses, reasoningEffort optional', () => {
  assert.deepEqual(
    modelSelectRequestOf({ sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' }),
    { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' },
  )
  assert.deepEqual(
    modelSelectRequestOf({ sessionId: 's', provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' }),
    { sessionId: 's', provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' },
  )
})

test('model-select: malformed payloads are refused, not normalized (fail-closed, 写路径纪律)', () => {
  for (const bad of [
    {},
    { sessionId: 's', provider: 'deepseek' },
    { sessionId: 's', model: 'deepseek-chat' },
    { provider: 'deepseek', model: 'deepseek-chat' },
    { sessionId: '', provider: 'deepseek', model: 'deepseek-chat' },
    { sessionId: 's', provider: '', model: 'deepseek-chat' },
    { sessionId: 's', provider: 'deepseek', model: 7 },
    { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat', reasoningEffort: '' },
  ]) {
    assert.equal(modelSelectRequestOf(bad), undefined, JSON.stringify(bad))
  }
})

test('model-select: accepted selection comes back as the normalized choice', async () => {
  const reply = await handle(
    { v: 2, op: 'model-select', sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' },
    PORT, undefined, undefined, fakeWritePort(), fakeModel(),
  )
  assert.deepEqual(reply, {
    v: 2,
    ok: true,
    selected: { provider: 'deepseek', model: 'deepseek-chat' },
  })
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
  const reply = await handle(
    { v: 2, op: 'model-select', sessionId: 's', provider: 'x', model: 'm' },
    PORT, undefined, undefined, fakeWritePort(), refusing,
  )
  assert.deepEqual(reply, {
    v: 2,
    ok: false,
    error: { code: 'session/model-unavailable', message: 'no adapter serves provider "x"' },
  })
})

test('model-select: malformed payload is invalid-request, never reaches the port', async () => {
  const model = fakeModel()
  let asked = false
  const spy: ModelPort = { ...model, select: async (r) => { asked = true; return model.select(r) } }
  const reply = await handle(
    { v: 2, op: 'model-select', sessionId: 's', provider: '' , model: 'm' },
    PORT, undefined, undefined, fakeWritePort(), spy,
  )
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'invalid-request')
  assert.equal(asked, false)
})

test('model-catalog: a wedged catalog source is an internal-error envelope, not a crash', async () => {
  const model = fakeModel()
  const reply = await handle({ v: 2, op: 'model-catalog' }, PORT, undefined, undefined, undefined, {
    ...model,
    catalog: async () => {
      throw new Error('registry exploded')
    },
  })
  assert.deepEqual(reply, {
    v: 2,
    ok: false,
    error: { code: 'internal-error', message: 'registry exploded' },
  })
})
