/**
 * 模型基线**经 HTTP `snapshot`** 的那条出口：读的是同一份 `modelSelection` 投影视图，
 * 交出去的必须是投影的 `next`。
 *
 * WS 那条出口本期已经没有了 —— 打开帧改成转发上游 `snapshot` 之后，网关不再往里加
 * 任何一格（判据：`remote/stream.test.ts` 的「the opening carries no model」）。
 * 这条 HTTP 出口本身也在第 2 期的 `session/page` 转发里退场，届时本文件随之删除。
 *
 * 为什么这条判据要接到真实来源上：宿主给的是 `{lastUsed, next}` 两格的视图，而协议要的是
 * 「下一轮将用什么」这一个选择。`lastUsed` 是**上一轮**用了什么，把它或整份视图发出去，
 * 手机端逐字段解码就会失败、静默退到目录默认值 —— 而两侧都不会报错（修之前端口出参是
 * `unknown`，装配层填什么都编译得过）。所以假件替代的是**宿主的投影服务**
 * （`snapshot(session, keys)` 返回 `{ asOfSeq, values }`），不是我们自己的端口；
 * 后者由 `*Over(ctx)` 工厂接上，提取、帧装配、线上传输全是真的。
 *
 * Run: node --test tests/model-baseline.test.ts
 */
import assert from 'node:assert/strict'
import test from 'node:test'
import { modelSelectionSourceOver } from '../src/upstream/faces.ts'
import { createSessionPort, type PersistenceLike } from '../src/upstream/sessions.ts'
import type { ModelSelection } from '../src/wire/model.ts'

/** 宿主 `modelSelection` 投影的原样视图：两格都在，`next` 与 `lastUsed` 不同 ——
 * 取错了哪一格，断言会直接看出来。 */
const HOST_VIEW = {
  lastUsed: { provider: 'deepseek', model: 'chat', reasoningEffort: 'medium' },
  next: { provider: 'deepseek', model: 'reasoner', reasoningEffort: 'high' },
}

/** 期望的基线：投影的 `next`，一个字都不多。 */
const EXPECTED: ModelSelection = { provider: 'deepseek', model: 'reasoner', reasoningEffort: 'high' }

type HostContext = Parameters<typeof modelSelectionSourceOver>[0]

/**
 * 假宿主：只提供两条出口真正读到的服务，形状照运行时 —— `sessions.get(id)` 拿到会话对象，
 * `sessionProjections.snapshot(session, keys)` 拿到 `{ asOfSeq, values }`，
 * `sessionController.follow` 吐出一次 snapshot 帧。
 *
 * `snapshot` **尊重 `keys`**：只物化被点名的那一格。这不是细节 —— 真宿主按 `keys` 取投影，
 * 键名写错在线上就是「基线永远缺席」；假件若不看 `keys`，读取点把键改成任意错名，
 * 本文件的断言仍然全绿（那正是本期缺陷的同型失败：测试绿、手机错）。
 */
function fakeHost(view: unknown): HostContext {
  const session = { id: 's1' }
  const available: Record<string, unknown> = view === undefined ? {} : { modelSelection: view }
  return {
    sessions: { get: (id: string) => (id === 's1' ? session : undefined) },
    sessionProjections: {
      snapshot: (_session: unknown, keys?: readonly string[]) => {
        const values: Record<string, unknown> = {}
        for (const key of keys ?? Object.keys(available)) {
          if (key in available) values[key] = available[key]
        }
        return { asOfSeq: 7, values }
      },
    },
    sessionController: {
      async *follow() {
        yield {
          type: 'snapshot' as const,
          cursor: 0,
          records: [{ type: 'event' as const, event: { type: 'user/message', seq: 0, time: 1, data: {} } }],
          hasMore: false,
        }
      },
    },
  } as unknown as HostContext
}

/** 读一条日志的假持久化 —— 与宿主无关，只为让 `read` 走完它自己那段。 */
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

/** HTTP 那条出口的基线。 */
async function baselineOverHttp(view: unknown): Promise<unknown> {
  const ctx = fakeHost(view)
  const port = createSessionPort(oneEventPersistence(), modelSelectionSourceOver(ctx))
  const slice = await port.read('s1', 0, 10)
  assert.ok(slice !== undefined, 'the read must find the session')
  return 'model' in slice ? slice.model : undefined
}

test('the snapshot hands out the projection next — never the whole view, never lastUsed', { timeout: 15_000 }, async () => {
  assert.deepEqual(await baselineOverHttp(HOST_VIEW), EXPECTED,
    'the selection itself: `{provider, model, …}`, not the host view `{lastUsed, next}`')
})

test('a projection without next leaves the field out, never null and never a default', { timeout: 15_000 }, async () => {
  const noNext = { lastUsed: HOST_VIEW.lastUsed, next: null }
  assert.equal(await baselineOverHttp(noNext), undefined, 'no baseline, the field is absent')
})

test('a projection that lacks modelSelection is honestly absent', { timeout: 15_000 }, async () => {
  // 覆盖面是「投影未装 / 视图缺席」，不含「会话不存在」—— `fakeHost` 仍让
  // `sessions.get('s1')` 返回会话对象。后者由 `modelBaselineOf` 的第一句挡掉，
  // 那条分支的判据在读取处，不在这里。
  assert.equal(await baselineOverHttp(undefined), undefined, 'no projection, nothing to say')
})
