/**
 * Adapter tests: how one list row is assembled.
 *
 * The row comes from a header plus a host-kept projection, never from reading a log.
 * Two things need pinning: where each field comes from, and that no log is ever
 * opened — proved by a persistence stub that throws if anything opens a handle.
 * Run: node --test tests/upstream/sessions.test.ts
 * See dev/contract/protocol.md §4.1 and M1 §3.2.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createSessionPort, nextOf } from '../../src/upstream/sessions.ts'
import type { ListRecord, ListSource, PersistenceLike } from '../../src/upstream/sessions.ts'

/** A session header as the adapter sees it. `cwd` decides visibility (v2 keeps v1's rule). */
function header(
  id: string,
  createdAt: number,
  extra: Partial<{ cwd: string; isSeeded: boolean; origin: string }> = {},
): { id: string; createdAt: number; cwd?: string; isSeeded?: boolean; origin?: string } {
  return { id, createdAt, cwd: '/tmp/work', ...extra }
}

/**
 * A persistence that fails loudly if the list path touches it: "listing is zero-I/O"
 * is otherwise a claim about code we do not run.
 */
function logForbiddingPersistence(): PersistenceLike {
  return {
    async open() {
      throw new Error('the list path must not open a session log')
    },
  }
}

/** A {@link ListSource} over fixed records, with per-case overrides. */
function sourceOf(records: readonly ListRecord[], overrides: Partial<ListSource> = {}): ListSource {
  return {
    async records() {
      return records
    },
    liveValues() {
      return undefined
    },
    storedValues() {
      return undefined
    },
    isRunning() {
      return false
    },
    ...overrides,
  }
}

test('a cold session takes its title, blank and updatedAt from the stored projection', async () => {
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [{ header: header('s-1', 1000), live: false }],
    {
      storedValues: () => ({
        title: '聊过的题目',
        sessionListMetadata: { blank: false, lastPromptAt: 2000 },
      }),
    },
  ))

  assert.deepEqual(await port.list(), [
    { id: 's-1', title: '聊过的题目', createdAt: 1000, updatedAt: 2000, running: false, blank: false },
  ])
})

test('a session with no projection degrades to header facts rather than reaching for the log', async () => {
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [{ header: header('s-1', 1000), live: false }],
  ))

  const rows = await port.list()
  assert.deepEqual(rows, [{ id: 's-1', createdAt: 1000, updatedAt: 1000, running: false, blank: false }])
  assert.equal('title' in (rows[0] ?? {}), false, 'a missing title is an absent key, not an empty one')
})

test('a live session reads the live projection and never the stored cache', async () => {
  let storedAsked = false
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [{ header: header('s-1', 1000), live: true }],
    {
      liveValues: () => ({ title: '内存里的标题', sessionListMetadata: { blank: false, lastPromptAt: 3000 } }),
      storedValues: () => {
        storedAsked = true
        return { title: '磁盘上的旧标题' }
      },
    },
  ))

  const rows = await port.list()
  assert.equal(rows[0]?.title, '内存里的标题')
  assert.equal(rows[0]?.updatedAt, 3000)
  assert.equal(storedAsked, false, 'a running session is served from memory, not from a checkpoint')
})

test('a seeded session does not consult the projection cache at all', async () => {
  let asked = false
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [{ header: header('s-1', 1000, { isSeeded: true }), live: false }],
    {
      storedValues: () => {
        asked = true
        return { title: '不该用到' }
      },
    },
  ))

  const rows = await port.list()
  assert.equal(asked, false, 'a seeded log has an inherited prefix the caller cannot name')
  assert.equal(rows[0]?.title, undefined)
  assert.equal(rows[0]?.updatedAt, 1000)
})

test('the later of createdAt and the last prompt time wins', async () => {
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [
      { header: header('newer-prompt', 1000), live: false },
      { header: header('stale-prompt', 9000), live: false },
    ],
    {
      storedValues: (h) => h.id === 'newer-prompt'
        ? { sessionListMetadata: { blank: false, lastPromptAt: 5000 } }
        : { sessionListMetadata: { blank: false, lastPromptAt: 4000 } },
    },
  ))

  const rows = await port.list()
  assert.equal(rows.find(row => row.id === 'newer-prompt')?.updatedAt, 5000)
  assert.equal(rows.find(row => row.id === 'stale-prompt')?.updatedAt, 9000, 'a prompt older than creation cannot move the row back')
})

test('a session without a cwd is skipped before any projection lookup', async () => {
  // Which ids were looked up, not just "whether": the visible session must still
  // be looked up, so a boolean would not tell the two apart.
  const lookedUp: string[] = []
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [
      { header: { id: 'no-cwd', createdAt: 1000 }, live: false },
      { header: header('has-cwd', 2000), live: false },
    ],
    {
      storedValues: (h) => {
        lookedUp.push(h.id)
        return { title: '可见的那个' }
      },
    },
  ))

  const rows = await port.list()
  assert.deepEqual(rows.map(row => row.id), ['has-cwd'])
  assert.deepEqual(lookedUp, ['has-cwd'], 'an invisible session is dropped before it can cost a cache read')
})

test('running comes from the runtime, not from the projection', async () => {
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [{ header: header('s-1', 1000), live: true }],
    { isRunning: id => id === 's-1' },
  ))

  const rows = await port.list()
  assert.equal(rows[0]?.running, true)
})

test('blank defaults to false when the projection does not say', async () => {
  const port = createSessionPort(logForbiddingPersistence(), sourceOf(
    [{ header: header('s-1', 1000), live: false }],
    { storedValues: () => ({ title: '有标题但没说 blank' }) },
  ))

  const rows = await port.list()
  assert.equal(rows[0]?.blank, false)
})

test('origin comes from the header and is absent for an ordinary session', async () => {
  const port = createSessionPort(logForbiddingPersistence(), sourceOf([
    { header: header('child', 2000, { origin: 'subagent' }), live: false },
    { header: header('parent', 1000), live: false },
  ]))

  const rows = await port.list()
  assert.equal(rows.find(row => row.id === 'child')?.origin, 'subagent')
  assert.equal('origin' in (rows.find(row => row.id === 'parent') ?? {}), false)
})

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

/** A record the read path can find by id. */
const READ_RECORD: ListRecord = { header: header('s-1', 1000), live: true }

test('the slice carries the model baseline the source hands out', async () => {
  // 来源交出的是**选择本身**（宿主视图 `{lastUsed, next}` 已在读取处提取过）——
  // 这条断言因此只能喂选择，喂视图在类型上就不成立。
  const port = createSessionPort(oneEventPersistence(), sourceOf([READ_RECORD]), {
    of() {
      return { provider: 'deepseek', model: 'v3.2' }
    },
  })
  const slice = await port.read('s-1', 0, 10)
  assert.ok(slice)
  assert.deepEqual(slice.model, { provider: 'deepseek', model: 'v3.2' })
})

test('an absent projection leaves the model field absent, never guessed', async () => {
  const port = createSessionPort(oneEventPersistence(), sourceOf([READ_RECORD]), {
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
  assert.equal(nextOf({ next: null }), undefined)
  assert.equal(nextOf({ next: undefined }), undefined)
  assert.equal(nextOf({}), undefined)
  const selection = { provider: 'deepseek', model: 'v3.2' }
  assert.deepEqual(nextOf({ next: selection }), selection, 'the selection itself passes through untouched')
})
