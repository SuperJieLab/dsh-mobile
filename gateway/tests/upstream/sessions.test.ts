/**
 * `createSessionPort` 的读路径：`snapshot` / `page` 用的切片，以及它带的模型基线。
 *
 * 列表不在这里 —— 它已改为转发宿主的 `session/list`（`tests/protocol/list-forward.test.ts`）。
 * 这条文件只问「一条日志怎么切片」。
 *
 * Run: node --test tests/upstream/sessions.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import { createSessionPort, nextOf, type PersistenceLike } from '../../src/upstream/sessions.ts'

// MARK: - the opening model baseline (M7 T4, G3)

/** A persistence serving exactly one event, so `read` reaches the slice path. */
function oneEventPersistence(): PersistenceLike {
  return {
    async open() {
      return {
        async read() {
          return { events: [{ type: 'user/message', seq: 0, time: 1, data: {} }] }
        },
        async close() {},
      }
    },
  }
}

test('the slice carries the model baseline the source hands out', async () => {
  // 来源交出的是**选择本身**（宿主视图 `{lastUsed, next}` 已在读取处提取过）——
  // 这条断言因此只能喂选择，喂视图在类型上就不成立。
  const port = createSessionPort(oneEventPersistence(), {
    of() {
      return { provider: 'deepseek', model: 'v3.2' }
    },
  })
  const slice = await port.read('s-1', 0, 10)
  assert.ok(slice)
  assert.deepEqual(slice.model, { provider: 'deepseek', model: 'v3.2' })
})

test('an absent projection leaves the model field absent, never guessed', async () => {
  const port = createSessionPort(oneEventPersistence(), {
    of() {
      return undefined
    },
  })
  const slice = await port.read('s-1', 0, 10)
  assert.ok(slice)
  assert.equal('model' in slice, false)
})

test('nextOf turns an empty next into nothing — null and undefined alike', () => {
  // 「投影的空值」与「没有基线」是同一件事，但表现形式有两种；把这个转换放在
  // 一个有名字的函数里，是因为它是宿主形状与我们的形状之间唯一的转换点。
  // 分片层因此不必再判空值 —— 它收到的不是「视图」而是「选择或没有选择」。
  assert.equal(nextOf({ next: null }), undefined)
  assert.equal(nextOf({ next: undefined }), undefined)
  assert.equal(nextOf({}), undefined)
  const selection = { provider: 'deepseek', model: 'v3.2' }
  assert.deepEqual(nextOf({ next: selection }), selection, 'the selection itself passes through untouched')
})
