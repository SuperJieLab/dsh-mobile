/**
 * `session/list`：宿主的列表**原样**出去。
 *
 * 这一层只问一件事 —— 网关有没有在中间加工。所以判据给一个「上游形状」的假值，
 * 要求回来的**逐字相同**：多一格说明我们补了，少一格说明我们裁了，改一格说明我们
 * 换了名字。三者都是「网关重算列表」的残留，也正是这一期要消灭的东西。
 *
 * 归属与分组**不在这里**：它们已经搬去 `workspace/follow` 的流（见 `workspace-stream`）。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, valueOf } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'

function portWith(list: SessionPort['list']): SessionPort {
  return { list, page: async () => ({ records: [], hasMore: false, cursor: -1 }) }
}

/** 上游 `SessionListValue` 的一份样本：`items` 里那一行的字段就是它的全部字段。 */
const HOST_VALUE = {
  items: [
    {
      agentAvailable: true,
      sessionId: 's1',
      updatedAt: 1_700_000_200_000,
      running: false,
      blank: false,
      cwd: '/Users/someone/work/demo',
      projections: {
        kind: 'cached' as const,
        asOfSeq: 17,
        values: { title: '在跑的会话' },
      },
    },
    {
      agentAvailable: false,
      formatStatus: 'current' as const,
      sessionId: 's2',
      updatedAt: 1_700_000_100_000,
      running: false,
      blank: true,
    },
  ],
}

test('session/list hands the host value through untouched', async () => {
  const result = await invoke('session/list', { _request: {} }, { session: portWith(async () => HOST_VALUE) })
  assert.deepEqual(valueOf(result), HOST_VALUE,
    '网关补一格、裁一格或改一格名，都会让手机端的行与 Web UI 的行长得不一样')
})

test('session/list passes the request through as the host expects it', async () => {
  const seen: unknown[] = []
  await invoke('session/list', { _request: { cursor: 'c-1' } }, {
    session: portWith(async request => {
      seen.push(request)
      return HOST_VALUE
    }),
  })
  assert.deepEqual(seen, [{ cursor: 'c-1' }],
    '`_request` 的内层原样交给宿主，网关不重排也不补默认值')
})

test('the old endpoint name answers unknown-endpoint', async () => {
  // 旧名是**断言对象**：这条判据要证明它已被摘掉，就不得不写出它（`terms-ok` 只豁免这一行）。
  const result = await invoke('mobile/listSessions', {}, { session: portWith(async () => HOST_VALUE) }) // terms-ok: 退场端点名，本行是断言对象
  assert.equal(result.ok, false)
  assert.equal(result.ok ? '' : result.error.code, 'unknown-endpoint',
    '两端同版，改名不留别名 —— 留了就等于有两份名字知识')
})

test('a host failure folds into a refusal instead of escaping', async () => {
  const result = await invoke('session/list', { _request: {} }, {
    session: portWith(async () => { throw new Error('projection cache unreadable') }),
  })
  assert.equal(result.ok, false)
  assert.equal(result.ok ? '' : result.error.code, 'internal-error',
    '宿主抛错要在信封里折成拒绝；逃出去的表现是连接被掐，客户端只看得到传输失败')
})
