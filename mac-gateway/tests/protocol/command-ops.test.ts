/**
 * 两条命令 op 经 `handle` 的分派与应答形状。命令端口是假件：无网络、无 DSH 运行时。
 *
 * 分派与处理器在 `protocol/rpc.ts`；载荷解析在 `wire/command.ts`；宿主怎么列、怎么执行
 * 在 `upstream/command.ts`，另有其测试。
 *
 * 这里钉的两件事最容易被写错：**回包只表示受理**（结果在流里），以及**未知命令不当成功**。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { CommandPort } from '../../src/ports/command.ts'
import { commandExecuteRequestOf } from '../../src/wire/command.ts'

// -- helpers -----------------------------------------------------------------

const PORT: SessionPort = { list: async () => [], read: async () => undefined, readAll: async () => undefined }

/** 假命令端口：记下每次调用的实参，便于断言「有没有真的到宿主」。 */
function fakeCommand(overrides: Partial<CommandPort> = {}): CommandPort & { calls: { sessionId: string; line: string }[] } {
  const calls: { sessionId: string; line: string }[] = []
  return {
    calls,
    async list() {
      return [
        { name: 'permission', description: 'Switch the permission preset', inputHint: '<preset>' },
        { name: 'compact', description: 'Compact the conversation' },
      ]
    },
    async execute(sessionId, line) {
      calls.push({ sessionId, line })
      return { ok: true, commandId: 'cmd-1' }
    },
    ...overrides,
  }
}

// -- command-catalog (U1 / U2) -----------------------------------------------

test('command-catalog: the host command list comes back verbatim', async () => {
  const reply = await handle({ v: 2, op: 'command-catalog', sessionId: 's' },
    PORT, undefined, undefined, undefined, undefined, fakeCommand())
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  assert.deepEqual(reply.commands, [
    { name: 'permission', description: 'Switch the permission preset', inputHint: '<preset>' },
    { name: 'compact', description: 'Compact the conversation' },
  ])
})

test('command-catalog: a descriptor without an input hint carries no inputHint key', async () => {
  const reply = await handle({ v: 2, op: 'command-catalog', sessionId: 's' },
    PORT, undefined, undefined, undefined, undefined, fakeCommand())
  assert.equal(reply.ok, true)
  if (!reply.ok) return
  const commands = reply.commands as { name: string; inputHint?: string }[]
  // 第二个描述符没有 input.hint —— 字段缺席，不是空串；客户端据此决定要不要显示占位提示。
  assert.equal('inputHint' in (commands[1] ?? {}), false)
})

// -- command-execute 的载荷校验（写路径纪律）----------------------------------

test('command-execute: a line must start with a slash and be non-empty', () => {
  assert.deepEqual(commandExecuteRequestOf({ sessionId: 's', line: '/permission read-only' }),
    { sessionId: 's', line: '/permission read-only' })
  for (const bad of [
    {},
    { sessionId: 's' },
    { line: '/permission' },
    { sessionId: '', line: '/permission' },
    { sessionId: 's', line: '' },
    { sessionId: 's', line: 'permission' },
    { sessionId: 's', line: ' /permission' },
    { sessionId: 's', line: 7 },
  ]) {
    assert.equal(commandExecuteRequestOf(bad), undefined, JSON.stringify(bad))
  }
})

test('command-execute: a well-formed line reaches the port verbatim, with arguments intact', async () => {
  const command = fakeCommand()
  const reply = await handle({ v: 2, op: 'command-execute', sessionId: 's', line: '/goal 把剩下的活干完' },
    PORT, undefined, undefined, undefined, undefined, command)
  assert.equal(reply.ok, true)
  // 整行原样：不 trim、不重新拼参数 —— 语法归宿主，我们只转达。
  assert.deepEqual(command.calls, [{ sessionId: 's', line: '/goal 把剩下的活干完' }])
})

test('command-execute: the reply carries only the acceptance id, never a result', async () => {
  const reply = await handle({ v: 2, op: 'command-execute', sessionId: 's', line: '/compact' },
    PORT, undefined, undefined, undefined, undefined, fakeCommand())
  // 结果从流里来（command/run + command/done）。回包里多一个 result 字段，
  // 就多一处会与流里那条说法分叉的地方。
  assert.deepEqual(reply, { v: 2, ok: true, commandId: 'cmd-1' })
})

test('command-execute: an unparsable name is unknown-command, not success', async () => {
  const command = fakeCommand({
    execute: async () => ({ ok: false, code: 'unknown-command', message: 'no such command: /nosuchcmd' }),
  })
  const reply = await handle({ v: 2, op: 'command-execute', sessionId: 's', line: '/nosuchcmd' },
    PORT, undefined, undefined, undefined, undefined, command)
  assert.deepEqual(reply, {
    v: 2,
    ok: false,
    error: { code: 'unknown-command', message: 'no such command: /nosuchcmd' },
  })
})

test('command-execute: a line that is not a command is invalid-request, never reaches the port', async () => {
  const command = fakeCommand()
  const reply = await handle({ v: 2, op: 'command-execute', sessionId: 's', line: 'hello there' },
    PORT, undefined, undefined, undefined, undefined, command)
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'invalid-request')
  assert.deepEqual(command.calls, [], '畸形载荷绝不进宿主')
})

test('command-catalog: a missing session is unknown-session, not an empty list', async () => {
  const command = fakeCommand({ list: async () => undefined })
  const reply = await handle({ v: 2, op: 'command-catalog', sessionId: 'gone' },
    PORT, undefined, undefined, undefined, undefined, command)
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'unknown-session')
})

test('command ops: an unwired command channel is internal-error on both', async () => {
  for (const message of [
    { v: 2, op: 'command-catalog', sessionId: 's' },
    { v: 2, op: 'command-execute', sessionId: 's', line: '/compact' },
  ]) {
    const reply = await handle(message, PORT)
    assert.equal(reply.ok, false, JSON.stringify(message))
    if (!reply.ok) assert.equal(reply.error.code, 'internal-error')
  }
})
