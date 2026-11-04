/**
 * 版本闸：说不到一块儿去的时候，立刻说清楚，而不是静默错位。
 *
 * 这里守的是三件事，都不是「某个 op 的行为」：
 *
 * 1. **版本闸在 op 判断之前**。先解决版本，再谈这个 op 认不认识 —— 反过来会让
 *    「版本不对」被报成「不认识的 op」，人去翻协议表了。
 * 2. **没有一个 op 能绕过它**。漏一个分支就是漏一条路，而那种漏法在正常版本下
 *    永远不会显形。
 * 3. **文案带方向**。客户端旧还是网关旧，要能从拒绝里读出来。
 *
 * Run: node --test tests/protocol/version-gate.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import { handle } from '../../src/protocol/rpc.ts'
import type { Ports } from '../../src/protocol/rpc.ts'
import { PROTOCOL_VERSION } from '../../src/wire/rpc.ts'
import type { ErrorResponse } from '../../src/wire/rpc.ts'

/** 只读端口给最小假件：版本不对时连它都不该被碰。 */
const ports: Ports = {
  session: {
    list: async () => [],
    read: async () => undefined,
    readAll: async () => undefined,
  },
}

/** 拒绝的信封。`handle` 从不让版本不匹配变成成功，所以这里可以直接断言形状。 */
async function refusalFor(message: unknown): Promise<ErrorResponse> {
  const answer = await handle(message, ports)
  assert.equal(answer.ok, false, '版本不对的请求绝不能被处理成成功')
  return answer as ErrorResponse
}

test('no op gets through a version the gateway does not speak', async () => {
  // 读 op、写 op、以及一个根本不存在的 op：三类的拒绝必须来自同一处。
  const ops = [
    'list-sessions',
    'snapshot',
    'page',
    'session-prompt',
    'workspace-delete',
    'no-such-op',
  ]
  for (const op of ops) {
    const answer = await refusalFor({ v: PROTOCOL_VERSION + 1, op })
    assert.equal(
      answer.error.code,
      'unsupported-version',
      `${op} 在版本不对时被别的东西拒了 —— 版本闸必须排在 op 判断之前`,
    )
  }
})

test('a version that is not a number is refused, not defaulted', async () => {
  // 缺 `v` 或写成字符串时**不能当当前版本**：那是最典型的一种静默降级。
  for (const v of [undefined, null, '2', 2.5]) {
    const answer = await refusalFor({ v, op: 'list-sessions' })
    assert.equal(answer.error.code, 'unsupported-version')
  }
})

test('the refusal says which side is behind', async () => {
  const older = await refusalFor({ v: PROTOCOL_VERSION - 1, op: 'list-sessions' })
  assert.match(older.error.message, /upgrade the client/)

  const newer = await refusalFor({ v: PROTOCOL_VERSION + 1, op: 'list-sessions' })
  assert.match(newer.error.message, /upgrade the gateway/)
})

test('the refusal carries both versions', async () => {
  // 只说「不一致」不够：查的人第一件事就是想知道两个数字各是多少。
  const answer = await refusalFor({ v: PROTOCOL_VERSION + 3, op: 'list-sessions' })
  assert.match(answer.error.message, new RegExp(`v${PROTOCOL_VERSION}`))
  assert.match(answer.error.message, new RegExp(`v${PROTOCOL_VERSION + 3}`))
})

test('a message that is not an object is refused the same way', async () => {
  // 敌意输入与版本不对共用一条路：都不该走到 op 判断。
  for (const message of [null, 'hello', 42, []]) {
    const answer = await refusalFor(message)
    assert.equal(answer.error.code, 'unsupported-version')
  }
})

test('the version is settled before the op is even looked at', async () => {
  // **这一条才是顺序的判据**：上面那些都带着合法的 `op`，两种顺序给出同一个答案。
  // 只有「op 缺失 + 版本不对」能分开它们 —— 版本闸先答 `unsupported-version`，
  // 反过来先答 `unknown-op`，人就跑去翻 op 表了。
  const answer = await refusalFor({ v: PROTOCOL_VERSION + 1 })
  assert.equal(
    answer.error.code,
    'unsupported-version',
    '版本不对时先答了别的东西 —— 版本闸必须排在 op 判断之前',
  )
})
