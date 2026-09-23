/**
 * The write contract's tests (M5, docs/dev/plans/M5-remote-intervention.md §五 W1–W3
 * plus the `handle` dispatch; W4's server-side rebuild was retired by 实施期
 * 修正 11 — rebuilding is the phone's display concern now). The port is a
 * fake; no runtime, no network.
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle, type SessionPort } from './rpc.ts'
import {
  ReplayTable,
  approvalAnswerOf,
  outcomeOfDecision,
  sessionPromptOf,
  type ApprovalAnswerMessage,
  type SessionPromptMessage,
  type WritePort,
} from './write.ts'

// -- helpers -----------------------------------------------------------------

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
    },
  }
}

// -- parsing (fail-closed, W3) -----------------------------------------------

test('approval-answer: well-formed payload parses', () => {
  assert.deepEqual(
    approvalAnswerOf({ eventId: 'a', decision: 'allow', answerId: 'k' }),
    { eventId: 'a', decision: 'allow', answerId: 'k' },
  )
})

test('approval-answer: malformed payloads are refused, not normalized', () => {
  for (const bad of [
    {},
    { eventId: 'a', decision: 'allow' },
    { eventId: 'a', decision: 'ALLOW', answerId: 'k' },
    { eventId: '', decision: 'allow', answerId: 'k' },
    { eventId: 'a', decision: 'allow', answerId: 7 },
  ]) {
    assert.equal(approvalAnswerOf(bad as Record<string, unknown>), undefined, JSON.stringify(bad))
  }
})

test('session-prompt: well-formed payload parses; blank text refused', () => {
  assert.deepEqual(
    sessionPromptOf({ sessionId: 's', text: ' hi ', promptId: 'p' }),
    { sessionId: 's', text: ' hi ', promptId: 'p' },
  )
  for (const bad of [
    { sessionId: 's', text: '   ', promptId: 'p' },
    { sessionId: 's', text: 'hi' },
    { sessionId: '', text: 'hi', promptId: 'p' },
  ]) {
    assert.equal(sessionPromptOf(bad as Record<string, unknown>), undefined, JSON.stringify(bad))
  }
})

test('decision maps onto the one-shot upstream vocabulary only', () => {
  assert.equal(outcomeOfDecision('allow'), 'allowed-once')
  assert.equal(outcomeOfDecision('deny'), 'rejected')
})

// -- replay table (W1) -------------------------------------------------------

test('replay table: first produce runs once, retries replay the first outcome', () => {
  const table = new ReplayTable<string>()
  let runs = 0
  const first = table.remember('k', () => { runs += 1; return 'first' })
  assert.equal(first.fresh, true)
  const retry = table.remember('k', () => { runs += 1; return 'second' })
  assert.equal(retry.fresh, false)
  assert.equal(retry.value, 'first')
  assert.equal(runs, 1)
})

// -- handle dispatch ---------------------------------------------------------

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
