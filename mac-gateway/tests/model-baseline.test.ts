/**
 * 模型基线的两条出口：同一份 `modelSelection` 投影视图，经 HTTP `snapshot`（`SessionPort.read`）
 * 与 WS follow 的 opening 必须给出同一个值 —— 都是投影的 `next`。
 *
 * 为什么这条判据要接到真实来源上：宿主给的是 `{lastUsed, next}` 两格的视图，而协议要的是
 * 「下一轮将用什么」这一个选择。`lastUsed` 是**上一轮**用了什么，把它或整份视图发出去，
 * 手机端逐字段解码就会失败、静默退到目录默认值 —— 而两侧都不会报错：端口出参不透明，
 * 装配层填什么都编译得过。所以假件替代的是**宿主的投影服务**（`snapshot(session, keys)`
 * 返回 `{ asOfSeq, values }`），不是我们自己的端口；后者由 `*Over(ctx)` 工厂接上，
 * 提取、帧装配、线上传输全是真的。
 *
 * Run: node --test tests/model-baseline.test.ts
 */
import assert from 'node:assert/strict'
import { once } from 'node:events'
import { createServer } from 'node:http'
import test from 'node:test'
import { attachStreamHandler, STREAM_PATH, type FollowSource } from '../src/remote/ws.ts'
import { modelSelectionSourceOver, streamSourceOver } from '../src/upstream/faces.ts'
import { createSessionPort, type ListRecord, type PersistenceLike } from '../src/upstream/sessions.ts'
import { followRequestOf } from '../src/contract/mux.ts'
import type { ModelSelection } from '../src/contract/model-selection.ts'

/** 宿主 `modelSelection` 投影的原样视图：两格都在，`next` 与 `lastUsed` 不同 ——
 * 取错了哪一格，断言会直接看出来。 */
const HOST_VIEW = {
  lastUsed: { provider: 'deepseek', model: 'chat', reasoningEffort: 'medium' },
  next: { provider: 'deepseek', model: 'reasoner', reasoningEffort: 'high' },
}

/** 期望的基线：投影的 `next`，一个字都不多。 */
const EXPECTED: ModelSelection = { provider: 'deepseek', model: 'reasoner', reasoningEffort: 'high' }

type HostContext = Parameters<typeof streamSourceOver>[0]

/**
 * 假宿主：只提供两条出口真正读到的服务，形状照运行时 —— `sessions.get(id)` 拿到会话对象，
 * `sessionProjections.snapshot(session, keys)` 拿到 `{ asOfSeq, values }`，
 * `sessionController.follow` 吐出一次 snapshot 帧。
 */
function fakeHost(view: unknown): HostContext {
  const session = { id: 's1' }
  return {
    sessions: { get: (id: string) => (id === 's1' ? session : undefined) },
    sessionProjections: {
      snapshot: () => ({ asOfSeq: 7, values: view === undefined ? {} : { modelSelection: view } }),
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

const LISTING = {
  async records(): Promise<readonly ListRecord[]> {
    return []
  },
  liveValues: () => undefined,
  storedValues: () => undefined,
  isRunning: () => false,
}

/** HTTP 那条出口的基线。 */
async function baselineOverHttp(view: unknown): Promise<unknown> {
  const ctx = fakeHost(view)
  const port = createSessionPort(oneEventPersistence(), LISTING, modelSelectionSourceOver(ctx))
  const slice = await port.read('s1', 0, 10)
  assert.ok(slice !== undefined, 'the read must find the session')
  return 'model' in slice ? slice.model : undefined
}

/**
 * WS 那条出口的基线：真监听、真 WebSocket、真流处理器；只取第一帧（opening）。
 * 判据是「手机收到什么」，所以收的是线上文本 —— 不是装配函数的返回值。
 */
async function baselineOverStream(view: unknown): Promise<{ model: unknown; present: boolean }> {
  const source: FollowSource = streamSourceOver(fakeHost(view))
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const address = server.address()
    assert.ok(address !== null && typeof address === 'object')
    const socket = new WebSocket(`ws://127.0.0.1:${address.port}${STREAM_PATH}`)
    try {
      await new Promise<void>((resolve, reject) => {
        socket.addEventListener('open', () => resolve(), { once: true })
        socket.addEventListener('error', () => reject(new Error('socket failed to open')), { once: true })
      })
      const opening = await new Promise<Record<string, unknown>>((resolve, reject) => {
        socket.addEventListener('message', event => {
          resolve(JSON.parse(String((event as { data: unknown }).data)) as Record<string, unknown>)
        }, { once: true })
        socket.addEventListener('error', () => reject(new Error('socket errored before the opening')), { once: true })
        socket.send(JSON.stringify({ type: 'open', streamId: 1, payload: { op: 'follow', sessionId: 's1' } }))
      })
      const payload = opening.payload as Record<string, unknown>
      return { model: payload.model, present: 'model' in payload }
    } finally {
      socket.close()
    }
  } finally {
    server.closeAllConnections()
    await new Promise<void>(resolve => { server.close(() => { resolve() }) })
  }
}

test('both exits hand out the projection next — never the whole view, never lastUsed', { timeout: 15_000 }, async () => {
  const overHttp = await baselineOverHttp(HOST_VIEW)
  const overStream = await baselineOverStream(HOST_VIEW)

  assert.deepEqual(overStream.model, EXPECTED,
    'the opening carries the selection itself: `{provider, model, …}`, not the host view `{lastUsed, next}`')
  assert.deepEqual(overHttp, EXPECTED, 'the snapshot carries the same selection')
  assert.deepEqual(overStream.model, overHttp, 'the two exits agree on the same projection view')
})

test('a projection without next leaves the field out of both exits, never null and never a default', { timeout: 15_000 }, async () => {
  const noNext = { lastUsed: HOST_VIEW.lastUsed, next: null }

  assert.equal(await baselineOverHttp(noNext), undefined, 'HTTP: no baseline, the field is absent')
  const overStream = await baselineOverStream(noNext)
  assert.equal(overStream.present, false, 'WS: no baseline, the field is absent — not null, not a guess')
})

test('an absent projection is honestly absent on both exits', { timeout: 15_000 }, async () => {
  assert.equal(await baselineOverHttp(undefined), undefined, 'HTTP: unknown session, nothing to say')
  const overStream = await baselineOverStream(undefined)
  assert.equal(overStream.present, false, 'WS: unknown session, nothing to say')
})

test('the follow request still parses without a model — the field is server-supplied', async () => {
  // 防一个容易写错的假设：`model` 不是客户端请求的字段，它是服务端读投影后送的基线。
  const parsed = followRequestOf({ op: 'follow', sessionId: 's1' })
  assert.equal(parsed?.sessionId, 's1')
})
