/**
 * `$events/result` 的转发面。
 *
 * 三条承诺：**归属**还是那一处判定；**结局**原样转发、网关不判「还在不在」；
 * **畸形**在到达宿主之前就被拒。
 *
 * 手机 `clientId` → 上游身份的换算不在这里：它在 `upstream/write.ts`，由
 * `tests/upstream/write.test.ts` 用两个不同的值钉住。
 *
 * Run: node --test tests/protocol/remote-event-result.test.ts
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, TEST_CALLER, TEST_CLIENT_ID, valueOf } from '../helpers/unary.ts'
import type { Identity } from '../../src/protocol/auth.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WritePort } from '../../src/ports/write.ts'
import type { RemoteEventResultMessage } from '../../src/wire/write.ts'

const PORT: SessionPort = { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

function recorder() {
  const answers: RemoteEventResultMessage[] = []
  const port: WritePort = {
    answerEvent: async (result) => { answers.push(result); return 'delivered' },
    promptSession: async () => 'accepted',
    createSession: async () => 's-unused',
  }
  return { answers, port }
}

const okArgs = {
  clientId: TEST_CLIENT_ID,
  eventId: 'e-1',
  outcome: { kind: 'result', value: 'allowed-once' },
}

test('归属还是那一处 —— 别人的流、没登记的流都答不了', async () => {
  const { answers, port } = recorder()

  const stranger = await invoke(
    '$events/result',
    { ...okArgs, clientId: 'c-someone-else' },
    { session: PORT, write: port },
    Date.now,
    { id: 'other', canAnswer: true } as Identity,
    { ownerOf: () => 'its-owner' },
  )
  assert.equal(stranger.ok, false)
  assert.equal(stranger.ok ? '' : stranger.error.code, 'not-owner')

  const unregistered = await invoke(
    '$events/result',
    { ...okArgs, clientId: 'c-never-opened' },
    { session: PORT, write: port },
  )
  assert.equal(unregistered.ok, false)
  assert.equal(unregistered.ok ? '' : unregistered.error.code, 'not-owner',
    '「从未下发」与「已经换代」对客户端是同一件事')

  assert.deepEqual(answers, [], '两次都没到上游')

  // 正控：本人的流照常投递。
  assert.deepEqual(valueOf(await invoke('$events/result', okArgs, { session: PORT, write: port })),
    { ok: true })
  assert.equal(answers.length, 1)
})

test('同一条答两次都回 ok —— 网关不做「还在不在」的判定', async () => {
  const { answers, port } = recorder()
  assert.deepEqual(valueOf(await invoke('$events/result', okArgs, { session: PORT, write: port })), { ok: true })
  assert.deepEqual(valueOf(await invoke('$events/result', {
    ...okArgs, outcome: { kind: 'result', value: 'rejected' },
  }, { session: PORT, write: port })), { ok: true })
  assert.equal(answers.length, 2, '两次都真的交给上游 —— 上游对已结算事件是幂等 no-op')
})

test('三种畸形 outcome 一律 invalid-request，宿主零调用', async () => {
  const { answers, port } = recorder()
  for (const outcome of [
    { kind: 'oops' },
    { kind: 'rejected' },
    { kind: 'rejected', error: { name: 'E', message: '' } },
  ]) {
    const result = await invoke('$events/result', { ...okArgs, outcome }, { session: PORT, write: port })
    assert.equal(result.ok, false, JSON.stringify(outcome))
    assert.equal(result.ok ? '' : result.error.code, 'invalid-request')
  }
  assert.deepEqual(answers, [])
})

test('三键平铺 —— 少 clientId / 少 eventId / 多一层容器都不合格', async () => {
  const { answers, port } = recorder()
  for (const args of [
    { eventId: 'e-1', outcome: { kind: 'result' } },
    { clientId: TEST_CLIENT_ID, outcome: { kind: 'result' } },
    { request: okArgs },
  ]) {
    const result = await invoke('$events/result', args as Record<string, unknown>, { session: PORT, write: port })
    assert.equal(result.ok, false, JSON.stringify(args))
    assert.equal(result.ok ? '' : result.error.code, 'invalid-request')
  }
  assert.deepEqual(answers, [], `「${TEST_CALLER.id}」的流也不能替一条坏请求开绿灯`)
})
