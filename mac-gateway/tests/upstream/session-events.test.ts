/**
 * 上游的会话列表事件 → 我们的行变更。
 *
 * 这一层是**唯一**认识 `api-session/added` 这类名字与它字段位置的地方：手机端从来
 * 看不见上游形状（与 `ports/events.ts` 的立场一致）。所以判据直接喂上游样本。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { sessionListChangeOf } from '../../src/upstream/session-events.ts'
import { sessionListRowOf } from '../../src/upstream/session-events.ts'

/** 一条 `api-session/added`：上游 `SessionSummary` 的形状（`types.ts`）。 */
function addedSummary(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    sessionId: 's1',
    updatedAt: 1_700_000_000_000,
    running: false,
    blank: false,
    agentAvailable: true,
    formatStatus: 'current',
    ...overrides,
  }
}

// -- 四种事件 ---------------------------------------------------------------

test('session events: an added event becomes a full row, title taken from its projection block', () => {
  const change = sessionListChangeOf('api-session/added', [addedSummary({
    projections: { kind: 'cached', values: { title: '部署脚本' } },
  })])

  assert.deepEqual(change, {
    kind: 'added',
    row: {
      id: 's1', title: '部署脚本',
      updatedAt: 1_700_000_000_000, running: false, blank: false,
    },
  }, '标题来自同一份事件里的投影格 —— 不必再查一次会话头')
})

test('session events: a missing title cell stays absent rather than becoming an empty string', () => {
  for (const projections of [
    undefined,
    { kind: 'cached', values: {} },
    { kind: 'cached', values: { title: null } },
  ]) {
    const change = sessionListChangeOf('api-session/added', [
      addedSummary(projections === undefined ? {} : { projections }),
    ])
    assert.equal(change?.kind, 'added')
    const row = change?.kind === 'added' ? change.row : undefined
    assert.equal(row !== undefined && 'title' in row, false,
      `投影缺席 / title 为 null 时字段整个缺席，实际：${JSON.stringify(row)}`)
  }
})

test('session events: subagent origin rides along so the client can hide it', () => {
  const change = sessionListChangeOf('api-session/added', [addedSummary({ origin: 'subagent' })])
  const row = change?.kind === 'added' ? change.row : undefined
  assert.equal(row?.origin, 'subagent')
})

test('session events: removed, status and activity carry exactly the fields of their event', () => {
  assert.deepEqual(sessionListChangeOf('api-session/removed', ['s7']), { kind: 'removed', id: 's7' })
  // 两个方向都要：只测 `true` 时，把 running 写成常量 `true` 的实现不会红 ——
  // 而「跑完了」这个方向恰好是用户最在意的那个（「进行中」不消失）。
  assert.deepEqual(sessionListChangeOf('api-session/status', ['s7', true]),
    { kind: 'status', id: 's7', running: true })
  assert.deepEqual(sessionListChangeOf('api-session/status', ['s7', false]),
    { kind: 'status', id: 's7', running: false })
  assert.deepEqual(sessionListChangeOf('api-session/activity', ['s7', 1_700_000_000_123]),
    { kind: 'activity', id: 's7', updatedAt: 1_700_000_000_123 })
})

// -- 认不出的 ---------------------------------------------------------------

test('session events: a non-array argument list is not a change (and does not throw)', () => {
  // 上游声明 args 是数组；协议被破坏时这一层要返回「认不出」，而不是让一个下标访问
  // 抛出去把整条事件泵带走。
  for (const args of [{}, null, undefined, 'api-session/added', 42]) {
    assert.equal(sessionListChangeOf('api-session/added', args), undefined,
      `${JSON.stringify(args)} 不该翻成变更，也不该抛`)
  }
})

test('session events: anything else is not a list change', () => {
  const others: [string, unknown[]][] = [
    ['api-session/error', ['s1', 'boom']],
    ['session/event', []],
    ['api-session/added', []],
    ['api-session/added', [{}]],
    ['api-session/removed', [42]],
    ['api-session/status', ['s1']],
    ['api-session/activity', ['s1', 'later']],
  ]
  for (const [event, args] of others) {
    assert.equal(sessionListChangeOf(event, args), undefined,
      `${event} 的参数 ${JSON.stringify(args)} 不该翻成变更`)
  }
})

// -- 与列表路径同源 ---------------------------------------------------------

test('session events: the row a change carries has the same shape a list row has', () => {
  // 两条路的「无标题」判定必须同源：列表路径把非字符串一律当缺席，事件路径也是。
  const change = sessionListChangeOf('api-session/added', [addedSummary({
    projections: { kind: 'cached', values: { title: 42 } },
  })])
  assert.equal(change?.kind, 'added')
  if (change?.kind !== 'added') return
  assert.equal('title' in change.row, false, '非字符串的标题格同样缺席')

  const direct = sessionListRowOf(addedSummary({ projections: { kind: 'cached', values: {} } }))
  assert.equal(direct?.id, 's1')
})
