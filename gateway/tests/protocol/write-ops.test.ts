/**
 * 两条写 op 经端点表的分派：写通道没接线时的拒绝、上游结论怎么变成协议应答。
 *
 * 这里只问「分派对不对」：载荷解析在 `wire/write.ts`，交付与上游身份在
 * `upstream/write.ts`。三条路径各有一处自己的判据，混在一个文件里时哪一层坏了都指不出。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, TEST_CLIENT_ID } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WritePort } from '../../src/ports/write.ts'
import type { RemoteEventResultMessage, SessionPromptMessage } from '../../src/wire/write.ts'

const PORT: SessionPort = { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

/** A fake write port that records what it was asked to do. */
function fakeWrite(): { port: WritePort; answers: RemoteEventResultMessage[]; prompts: SessionPromptMessage[] } {
  const answers: RemoteEventResultMessage[] = []
  const prompts: SessionPromptMessage[] = []
  return {
    answers,
    prompts,
    port: {
      async answerEvent(result) {
        answers.push(result)
        return result.eventId === '' ? 'undelivered' : 'delivered'
      },
      async promptSession(prompt) {
        prompts.push(prompt)
        return prompt.sessionId === 'missing' ? 'unknown-session' : 'accepted'
      },
      async createSession() {
        return 's-unused'
      },
    },
  }
}

test('the table dispatches $events/result to the write port and answers {ok:true}', async () => {
  const { port, answers } = fakeWrite()
  const args = { clientId: TEST_CLIENT_ID, eventId: 'a', outcome: { kind: 'result', value: 'allowed-once' } }
  const answer = await invoke('$events/result', args, { session: PORT, write: port })
  assert.deepEqual(answer, { ok: true, value: { ok: true } })
  assert.deepEqual(answers, [{ clientId: TEST_CLIENT_ID, eventId: 'a', outcome: { kind: 'result', value: 'allowed-once' } }],
    'outcome 原样到端口 —— 网关不改这一格')
})

test('an undelivered answer and a malformed request come back as protocol refusals', async () => {
  const { port } = fakeWrite()
  const undelivered = await invoke(
    '$events/result',
    { clientId: TEST_CLIENT_ID, eventId: 'gone', outcome: { kind: 'result', value: 'rejected' } },
    // 上游拒了：问题还挂着，这一发不能说 ok。
    { session: PORT, write: { ...port, answerEvent: async () => 'undelivered' } },
  )
  assert.equal(undelivered.ok, false)
  assert.equal(undelivered.ok ? '' : undelivered.error.code, 'internal-error')

  const malformed = await invoke('$events/result', { eventId: 'a' }, { session: PORT, write: port })
  assert.equal(malformed.ok, false)
  assert.equal(malformed.ok ? '' : malformed.error.code, 'invalid-request')
})

test('the table dispatches session-prompt; unknown session keeps the read-path code', async () => {
  const { port, prompts } = fakeWrite()
  const args = {
    request: { requestId: 'r', sessionId: 's', mode: 'queue', content: [{ type: 'text', text: 'hi' }] },
  }
  const ok = await invoke('session/prompt', args, { session: PORT, write: port })
  assert.deepEqual(ok, { ok: true, value: { accepted: true } })
  assert.equal(prompts[0]?.requestId, 'r', '宿主收到的就是客户端铸的那个关联 id')

  const missing = await invoke(
    'session/prompt',
    { request: { ...args.request, sessionId: 'missing' } },
    { session: PORT, write: port },
  )
  assert.equal(missing.ok, false)
  assert.equal(missing.ok ? '' : missing.error.code, 'unknown-session')
})

test('write ops without a wired channel refuse as internal-error, not unknown-op', async () => {
  const reply = await invoke(
    'session/prompt',
    { request: { requestId: 'r', sessionId: 's', mode: 'queue', content: [{ type: 'text', text: 'hi' }] } },
    { session: PORT },
  )
  assert.equal(reply.ok, false)
  assert.equal(reply.ok ? '' : reply.error.code, 'internal-error')
})
