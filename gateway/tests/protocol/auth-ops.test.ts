/**
 * 两条凭据在体内的端点的判定 —— 以及**四种配对失败措辞逐字不变**。
 *
 * 措辞是这条判据的重点：它从 `protocol/auth.ts` 的 `PairingOutcome` 一路走到手机上，
 * 中间任何一层改一个字，用户看到的那句话就变了。这里钉的是「搬家的过程中它没变」。
 *
 * 搬过两次家：先是 `handle` 的 switch → `handleAuthOp`，再是 `/rpc` → 端点表。
 * 每次搬完都留着同一组断言，因为它们是这两条端点唯一的行为承诺。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { pairOf, refreshOf, type AuthPort } from '../../src/protocol/auth-ops.ts'

/** 一个只回答「成 / 不成」的端口 —— 记录它收到了什么，不判对错。 */
function port(overrides: Partial<AuthPort> = {}): AuthPort & { calls: unknown[][] } {
  const calls: unknown[][] = []
  return {
    calls,
    pair(code) {
      calls.push(['pair', code])
      return { ok: true, deviceToken: 'device-1' }
    },
    refresh(deviceToken) {
      calls.push(['refresh', deviceToken])
      return { ok: true, accessToken: 'ticket-1', expiresAt: 5_000, deviceToken: 'device-2' }
    },
    ...overrides,
  }
}

test('pair success carries the device token and nothing else', () => {
  const answer = pairOf('123456', port())
  assert.deepEqual(answer, { ok: true, value: { deviceToken: 'device-1' } })
})

test('pair refusal is invalid-pairing-code and keeps the reason word for word', () => {
  // 四种失败各自的措辞都由规则层给（`CredentialVault.pair`），这一层只搬。
  // 逐字断言而不是「非空」：改一个字用户看到的话就变了，而那种改动不会让任何
  // 其它判据红。
  const reasons = [
    '配对码不对。',
    '配对码已过期 —— 在 Mac 上取一个新的。',
    '错太多次，配对码已作废 —— 在 Mac 上取一个新的。',
    '配对码应当是 6 位数字。',
  ]
  for (const reason of reasons) {
    const answer = pairOf('000000', port({ pair: () => ({ ok: false, reason }) }))
    assert.equal(answer.ok, false, `${reason}: 失败必须是 ok:false`)
    assert.equal(answer.ok === false && answer.error.code, 'invalid-pairing-code', `${reason}: 错误码`)
    assert.equal(answer.ok === false && answer.error.message, reason, `${reason}: 措辞必须原样到达`)
  }
})

test('refresh success carries the rotated device token', () => {
  const answer = refreshOf('device-1', port())
  assert.deepEqual(answer, {
    ok: true,
    value: {
      accessToken: 'ticket-1',
      expiresAt: 5_000,
      deviceToken: 'device-2',
    },
  })
})

test('refresh refusal is unauthenticated with the same sentence as before', () => {
  const answer = refreshOf('stale', port({ refresh: () => ({ ok: false }) }))
  assert.equal(answer.ok, false)
  assert.equal(answer.ok === false && answer.error.code, 'unauthenticated')
  assert.equal(answer.ok === false && answer.error.message, 'unknown device token — pair again',
               '这句话是客户端「回未配对态」的唯一线索，不能被改写')
})

test('a missing credential is handed to the rule layer, not rejected here', () => {
  // 判定不在这一层：缺字段照样往下传，由规则层拒（`bad-code-shape` 是它的四种之一）。
  // 在这里先拒会让「码是什么形状」有两处定义。
  const spy = port()
  pairOf(undefined, spy)
  assert.deepEqual(spy.calls, [['pair', undefined]])

  const spy2 = port()
  refreshOf(undefined, spy2)
  assert.deepEqual(spy2.calls, [['refresh', undefined]])
})
