/**
 * 两条写 op 经 `handle` 的分派：写通道没接线时的拒绝、上游结论怎么变成协议应答。
 *
 * 这里只问「分派对不对」：载荷解析在 `wire/write.ts`，重放表在 `upstream/write.ts`。
 * 三条路径各有一处自己的判据，混在一个文件里时哪一层坏了都指不出。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WritePort } from '../../src/ports/write.ts'
import type { ApprovalAnswerMessage, SessionPromptMessage } from '../../src/wire/write.ts'

const PORT: SessionPort = { list: async () => [], read: async () => undefined, readAll: async () => undefined }

/** A fake write port that records what it was asked to do. */
function fakeWrite(): { port: WritePort; answers: ApprovalAnswerMessage[]; prompts: SessionPromptMessage[] } {
  const answers: ApprovalAnswerMessage[] = []
  const prompts: SessionPromptMessage[] = []
  return {
    answers,
    prompts,
    port: {
      async answerApproval(answer) {
        answers.push(answer)
        return answer.eventId === '' ? 'unknown-approval' : 'delivered'
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

test('handle dispatches approval-answer to the write port and answers delivered', async () => {
  const { port } = fakeWrite()
  const answer = await handle(
    { v: 2, op: 'approval-answer', eventId: 'a', decision: 'allow', answerId: 'k' },
    PORT, undefined, undefined, port,
  )
  assert.deepEqual(answer, { v: 2, ok: true, eventId: 'a' })
})

test('handle: unknown-approval and invalid-request come back as protocol refusals', async () => {
  const { port } = fakeWrite()
  const unknown = await handle(
    { v: 2, op: 'approval-answer', eventId: 'gone', decision: 'allow', answerId: 'k' },
    PORT, undefined, undefined,
    { ...port, async answerApproval() { return 'unknown-approval' } },
  )
  assert.equal(unknown.ok, false)
  assert.equal(unknown.ok ? '' : unknown.error.code, 'unknown-approval')

  const malformed = await handle({ v: 2, op: 'approval-answer', eventId: 'a' }, PORT, undefined, undefined, port)
  assert.equal(malformed.ok, false)
  assert.equal(malformed.ok ? '' : malformed.error.code, 'invalid-request')
})

test('handle dispatches session-prompt; unknown session keeps the read-path code', async () => {
  const { port } = fakeWrite()
  const ok = await handle(
    { v: 2, op: 'session-prompt', sessionId: 's', text: 'hi', promptId: 'p' },
    PORT, undefined, undefined, port,
  )
  assert.deepEqual(ok, { v: 2, ok: true, sessionId: 's' })

  const missing = await handle(
    { v: 2, op: 'session-prompt', sessionId: 'missing', text: 'hi', promptId: 'p' },
    PORT, undefined, undefined, port,
  )
  assert.equal(missing.ok, false)
  assert.equal(missing.ok ? '' : missing.error.code, 'unknown-session')
})

test('write ops without a wired channel refuse as internal-error, not unknown-op', async () => {
  const reply = await handle({ v: 2, op: 'session-prompt', sessionId: 's', text: 'hi', promptId: 'p' }, PORT)
  assert.equal(reply.ok, false)
  assert.equal(reply.ok ? '' : reply.error.code, 'internal-error')
})
