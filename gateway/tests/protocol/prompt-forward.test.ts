/**
 * `session/prompt` 的转发面（判据 1、11）。
 *
 * 这条端点的承诺只有一句：**五个字段原样交给宿主**。网关不拼 `content`、不固定
 * `mode`、不丢时区，畸形载荷在到达宿主之前就被拒。
 *
 * Run: node --test tests/protocol/prompt-forward.test.ts
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, valueOf } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WritePort } from '../../src/ports/write.ts'
import type { SessionPromptMessage } from '../../src/wire/write.ts'

const PORT: SessionPort = { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

function recorder() {
  const prompts: SessionPromptMessage[] = []
  const port: WritePort = {
    answerEvent: async () => 'delivered',
    promptSession: async (prompt) => { prompts.push(prompt); return 'accepted' },
    createSession: async () => 's-unused',
  }
  return { prompts, port }
}

test('判据 1：五个字段逐字到宿主，steer 不被改回 queue', async () => {
  const { prompts, port } = recorder()
  const args = {
    request: {
      requestId: 'r-1',
      sessionId: 's-1',
      mode: 'steer',
      content: [{ type: 'text', text: ' 打断一下  ' }, { type: 'text', text: 'again' }],
      clientTimeZone: 'Asia/Shanghai',
    },
  }
  assert.deepEqual(valueOf(await invoke('session/prompt', args, { session: PORT, write: port })),
    { accepted: true })
  assert.deepEqual(prompts, [{
    requestId: 'r-1',
    sessionId: 's-1',
    mode: 'steer',
    content: [{ type: 'text', text: ' 打断一下  ' }, { type: 'text', text: 'again' }],
    clientTimeZone: 'Asia/Shanghai',
  }], '网关不拼内容、不固定 queue、不丢时区，也不改正文的空白')
})

test('时区缺了就缺席 —— 不补 null、不猜一个', async () => {
  const { prompts, port } = recorder()
  await invoke('session/prompt', {
    request: { requestId: 'r-1', sessionId: 's-1', mode: 'queue', content: [{ type: 'text', text: 'hi' }] },
  }, { session: PORT, write: port })
  assert.equal('clientTimeZone' in (prompts[0] ?? {}), false)
})

test('判据 11：五种畸形一律 invalid-request，宿主零调用', async () => {
  const { prompts, port } = recorder()
  const ok = { requestId: 'r-1', sessionId: 's-1', mode: 'queue', content: [{ type: 'text', text: 'hi' }] }
  const cases: [string, unknown][] = [
    ['缺容器', { ...ok }],
    ['缺 requestId', { request: { ...ok, requestId: undefined } }],
    ['mode 不认识', { request: { ...ok, mode: 'now' } }],
    ['content 空数组', { request: { ...ok, content: [] } }],
    ['content 里有非文本', { request: { ...ok, content: [{ type: 'image', data: 'x' }] } }],
  ]
  for (const [name, args] of cases) {
    const result = await invoke('session/prompt', args as Record<string, unknown>, { session: PORT, write: port })
    assert.equal(result.ok, false, `${name} 该被拒`)
    assert.equal(result.ok ? '' : result.error.code, 'invalid-request', `${name} 的码`)
  }
  assert.deepEqual(prompts, [], '一条都不该到达宿主 —— 畸形载荷被静默收下等于凭猜测运行命令')
})
