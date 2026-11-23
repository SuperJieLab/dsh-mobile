/**
 * 两条命令 op 的分派与应答形状。命令端口是假件：无网络、无 DSH 运行时。
 *
 * **形状照抄上游**：`commands/list` 收 `agentId`、回**裸数组**（不是 `{commands}`），
 * 描述符带 `definitionId` 与 `input:{hint, attachments?}`；`commands/execute` 收
 * `{agentId, line, submittedAttachments}`。改这些名字或容器，就是又把「网关自造一套」
 * 请回来。
 *
 * 这里钉的两件事最容易被写错：**回包只表示受理**（结果在流里），以及**未知命令不当成功**。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { invoke, valueOf } from '../helpers/unary.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { CommandPort } from '../../src/ports/command.ts'
import { commandExecuteRequestOf } from '../../src/wire/command.ts'

// -- helpers -----------------------------------------------------------------

const PORT: SessionPort = { list: async () => [], page: async () => ({ records: [], hasMore: false, cursor: -1 }) }

/** 假命令端口：记下每次调用的实参，便于断言「有没有真的到宿主」。 */
function fakeCommand(overrides: Partial<CommandPort> = {}): CommandPort & { calls: { agentId: string; line: string }[] } {
  const calls: { agentId: string; line: string }[] = []
  return {
    calls,
    async list() {
      return [
        {
          definitionId: 'permission',
          name: 'permission',
          description: 'Switch the permission preset',
          input: { hint: '<preset>' },
        },
        { name: 'compact', description: 'Compact the conversation' },
      ]
    },
    async execute(agentId, line) {
      calls.push({ agentId, line })
      return { ok: true, commandId: 'cmd-1' }
    },
    ...overrides,
  }
}

// -- commands/list -----------------------------------------------------------

test('commands/list: the value is a bare array, not a wrapper object', async () => {
  const reply = await invoke('commands/list', { agentId: 's' }, { session: PORT, command: fakeCommand() })
  const value = valueOf<unknown>(reply)
  assert.equal(Array.isArray(value), true, '上游这条回的是一串描述符；套一层 `{commands}` 就是自造容器')
})

test('commands/list: descriptors keep definitionId, name, description and the input object', async () => {
  const reply = await invoke('commands/list', { agentId: 's' }, { session: PORT, command: fakeCommand() })
  assert.deepEqual(valueOf(reply), [
    {
      definitionId: 'permission',
      name: 'permission',
      description: 'Switch the permission preset',
      input: { hint: '<preset>' },
    },
    { name: 'compact', description: 'Compact the conversation' },
  ], '描述符原样过去：`inputHint` 平铺成字符串会丢掉 `input.attachments` 那一格')
})

test('commands/list: a descriptor without input carries no input key', async () => {
  const reply = await invoke('commands/list', { agentId: 's' }, { session: PORT, command: fakeCommand() })
  const commands = valueOf<Record<string, unknown>[]>(reply)
  // 第二个描述符没有 input —— 字段缺席，不是空对象：客户端据此决定要不要显示占位提示。
  assert.equal('input' in (commands[1] ?? {}), false)
  assert.equal('inputHint' in (commands[1] ?? {}), false, '旧的平铺字段已经退场')
})

test('commands/list: a missing agent is unknown-session, not an empty array', async () => {
  const command = fakeCommand({ list: async () => undefined })
  const reply = await invoke('commands/list', { agentId: 'gone' }, { session: PORT, command: command })
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'unknown-session')
})

test('commands/list: the agent it was asked about is the one the port hears', async () => {
  const seen: string[] = []
  const command = fakeCommand({ list: async (agentId) => { seen.push(agentId); return [] } })
  await invoke('commands/list', { agentId: 'agent-9' }, { session: PORT, command })
  assert.deepEqual(seen, ['agent-9'], '线上叫 agentId —— 与宿主的参数名一致')
})

// -- commands/execute 的载荷校验（写路径纪律）----------------------------------

test('command-execute: an agent and a slashed line are required', () => {
  assert.deepEqual(
    commandExecuteRequestOf({ agentId: 'a', line: '/permission read-only', submittedAttachments: [] }),
    { agentId: 'a', line: '/permission read-only' })
  for (const bad of [
    {},
    { agentId: 'a' },
    { line: '/permission' },
    { agentId: '', line: '/permission' },
    { agentId: 'a', line: '' },
    { agentId: 'a', line: 'permission' },
    { agentId: 'a', line: ' /permission' },
    { agentId: 'a', line: 7 },
  ]) {
    assert.equal(commandExecuteRequestOf(bad), undefined, JSON.stringify(bad))
  }
})

test('command-execute: attachments are an empty array until phase 4 — anything else is refused', () => {
  const refused = { agentId: 'a', line: '/compact', submittedAttachments: [{ id: 'f1' }] }
  assert.equal(commandExecuteRequestOf(refused), undefined,
    '非空附件本期没接；静默丢掉会让「附件没生效」看起来像命令自己的问题')
  assert.deepEqual(commandExecuteRequestOf({ agentId: 'a', line: '/compact', submittedAttachments: [] }),
    { agentId: 'a', line: '/compact' })
})

test('command-execute: a well-formed line reaches the port verbatim, with arguments intact', async () => {
  const command = fakeCommand()
  const reply = await invoke('commands/execute',
    { agentId: 'a', line: '/goal 把剩下的活干完', submittedAttachments: [] },
    { session: PORT, command: command })
  assert.equal(reply.ok, true)
  // 整行原样：不 trim、不重新拼参数 —— 语法归宿主，我们只转达。
  assert.deepEqual(command.calls, [{ agentId: 'a', line: '/goal 把剩下的活干完' }])
})

test('command-execute: the reply carries only the acceptance id, never a result', async () => {
  const reply = await invoke('commands/execute',
    { agentId: 'a', line: '/compact', submittedAttachments: [] },
    { session: PORT, command: fakeCommand() })
  // 结果从流里来（command/run + command/done）。回包里多一个 result 字段，
  // 就多一处会与流里那条说法分叉的地方。
  assert.deepEqual(reply, { ok: true, value: { commandId: 'cmd-1' } })
})

test('command-execute: an unparsable name is unknown-command, not success', async () => {
  const command = fakeCommand({
    execute: async () => ({ ok: false, code: 'unknown-command', message: 'no such command: /nosuchcmd' }),
  })
  const reply = await invoke('commands/execute',
    { agentId: 'a', line: '/nosuchcmd', submittedAttachments: [] },
    { session: PORT, command: command })
  assert.deepEqual(reply, { ok: false, error: { code: 'unknown-command', message: 'no such command: /nosuchcmd', details: {} } })
})

test('command-execute: a line that is not a command is invalid-request, never reaches the port', async () => {
  const command = fakeCommand()
  const reply = await invoke('commands/execute',
    { agentId: 'a', line: 'hello there', submittedAttachments: [] },
    { session: PORT, command: command })
  assert.equal(reply.ok, false)
  if (!reply.ok) assert.equal(reply.error.code, 'invalid-request')
  assert.deepEqual(command.calls, [], '畸形载荷绝不进宿主')
})

test('command ops: an unwired command channel is internal-error on both', async () => {
  const calls: [string, Record<string, unknown>][] = [
    ['commands/list', { agentId: 'a' }],
    ['commands/execute', { agentId: 'a', line: '/compact', submittedAttachments: [] }],
  ]
  for (const [endpoint, args] of calls) {
    const reply = await invoke(endpoint, args, { session: PORT })
    assert.equal(reply.ok, false, endpoint)
    if (!reply.ok) assert.equal(reply.error.code, 'internal-error', endpoint)
  }
})
