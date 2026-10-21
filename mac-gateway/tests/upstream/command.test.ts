/**
 * 命令适配器的测试。控制器的假件逐字复刻**运行时**签名
 * （`commands/src/index.ts` 的 `@Remote list(agent)` 与
 * `@Remote execute(agent, line, submittedAttachments, signal)`）——
 * 与真实切面不同的假件会让漂移通过所有测试。
 *
 * 这里钉的两件事：**宿主给什么就转什么**（不补字段、不重排），以及
 * **`undefined` 是「没有这条命令」而不是异常也不是成功**。
 */

import assert from 'node:assert/strict'
import { test, mock } from 'node:test'

import { Context, Service } from '@deepseek-ai/cordis'
import { commandPortOver, type CommandsLike, type LiveAgentsLike } from '../../src/upstream/command.ts'

// -- helpers -----------------------------------------------------------------

/** 运行时的命令服务签名，逐字：list(agent)、execute(agent, line, attachments, signal)。 */
function fakeCommands(overrides: Partial<CommandsLike> = {}): CommandsLike & {
  lines: { agent: unknown; line: string; attachments: readonly never[] }[]
} {
  const lines: { agent: unknown; line: string; attachments: readonly never[] }[] = []
  return {
    lines,
    list(agent) {
      // 形参名必须与运行时逐字一致（签名检查读它）—— 但这里的假件不用这个值。
      void agent
      return [
        { name: 'compact', description: 'Compact the conversation' },
        { name: 'permission', description: 'Switch the permission preset', input: { hint: '<preset>' } },
      ]
    },
    async execute(agent, line, submittedAttachments, signal) {
      // 四个形参一名不少：签名检查比对的就是这张表，少写一个它就会一直报「变了」。
      void signal
      lines.push({ agent, line, attachments: submittedAttachments })
      return { commandId: 'cmd-1' }
    },
    ...overrides,
  }
}

/** 会话注册表：只有 `live` 里的 id 有存活 agent。 */
function fakeAgents(live: readonly string[] = ['s']): LiveAgentsLike {
  return { get: (id: string) => (live.includes(id) ? { id } : undefined) }
}

/** Run `body` with console.warn captured; returns what was warned. */
async function captureWarn(body: () => Promise<void>): Promise<string[]> {
  const warnings: string[] = []
  const spy = mock.method(console, 'error', (...parts: unknown[]) => { warnings.push(parts.map(String).join(' ')) })
  try {
    await body()
  } finally {
    spy.mock.restore()
  }
  return warnings
}

// -- list --------------------------------------------------------------------

test('list forwards every descriptor, mapping input.hint onto inputHint', async () => {
  const port = commandPortOver(fakeCommands(), fakeAgents())
  assert.deepEqual(await port.list('s'), [
    { name: 'compact', description: 'Compact the conversation' },
    { name: 'permission', description: 'Switch the permission preset', inputHint: '<preset>' },
  ])
})

test('list answers undefined — not an empty list — when the session has no live agent', async () => {
  const port = commandPortOver(fakeCommands(), fakeAgents([]))
  // 空列表会让客户端把「会话没了」读成「这个会话没有命令」，两者补救不同。
  assert.equal(await port.list('gone'), undefined)
})

// -- execute -----------------------------------------------------------------

test('execute hands the line over verbatim with an empty attachment list', async () => {
  const commands = fakeCommands()
  const port = commandPortOver(commands, fakeAgents())

  const warnings = await captureWarn(async () => {
    assert.deepEqual(await port.execute('s', '/permission read-only'), { ok: true, commandId: 'cmd-1' })
  })
  // 假件自称「与运行时逐字一致」，而没有断言的告警等于没说：少一个形参它就一直响。
  assert.deepEqual(warnings, [], warnings.join('\n'))
  assert.equal(commands.lines.length, 1)
  assert.equal(commands.lines[0]?.line, '/permission read-only')
  // 手机端期1 没有附件能力：恒为空数组，而不是省略这个实参。
  assert.deepEqual(commands.lines[0]?.attachments, [])
})

test('execute maps an unparsable line onto unknown-command instead of throwing', async () => {
  const port = commandPortOver(fakeCommands({ execute: async () => undefined }), fakeAgents())
  assert.deepEqual(await port.execute('s', '/nosuchcmd'),
    { ok: false, code: 'unknown-command', message: 'no such command: /nosuchcmd' })
})

test('execute refuses a session with no live agent without calling the host', async () => {
  const commands = fakeCommands()
  const port = commandPortOver(commands, fakeAgents([]))
  assert.deepEqual(await port.execute('gone', '/compact'),
    { ok: false, code: 'unknown-session', message: 'no live session "gone"' })
  assert.equal(commands.lines.length, 0)
})

// -- 装配期签名检查（与模型通道同款防线）--------------------------------------

test('a drifted execute parameter list warns at assembly time instead of feeding garbage', async () => {
  const commands = {
    ...fakeCommands(),
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    async execute(sessionId: unknown, _line: unknown, _attachments: unknown, _signal: unknown) {
      return { commandId: 'cmd-1' }
    },
  }
  const warnings = await captureWarn(async () => {
    commandPortOver(commands as unknown as CommandsLike, fakeAgents()).execute('s', '/compact').then(() => {})
  })
  assert.equal(warnings.length, 1, warnings.join('\n'))
  assert.match(warnings[0]!, /execute/)
  // 要说清上游现在是什么，而不只是「变了」—— 这句话的用处就在这儿。
  assert.match(warnings[0]!, /declares \(sessionId, _line/)
})

// -- 包装层（cordis 的服务成员代理）------------------------------------------

/**
 * 一个服务成员被 cordis 包过之后长什么样：`Function.prototype.toString` 只回
 * `function () { [native code] }`（`createShadowMethod` 那层 Proxy），原件留在原型上。
 *
 * 这一条来自真机日志：命令通道接上时 `list` 与 `execute` 各报一次「形参表变了」，
 * 而它们一字未变 —— 检查读的是包装。假件用真实的 `Service` 造，不手写包装：
 * 包装的形状属于宿主，我手写的那一版只能复刻我此刻想到的样子。
 */
async function cordisService(): Promise<CommandsLike> {
  class Commands extends Service {
    constructor(ctx: Context) {
      super(ctx, 'commands')
    }
    // 形参名与运行时逐字一致。
    list(agent: unknown): { name: string; description: string }[] {
      void agent
      return [{ name: 'compact', description: 'compact 的说明' }]
    }
    async execute(
      agent: unknown, line: string, submittedAttachments: readonly never[], signal: AbortSignal,
    ) {
      void [agent, line, submittedAttachments, signal]
      return { commandId: 'cmd-1' }
    }
  }
  const root = new Context()
  await root.plugin({
    name: 'commands-host',
    inject: [],
    apply: (ctx: Context) => { new Commands(ctx) },
  })
  return root.reflect.get('commands') as CommandsLike
}

test('a cordis-wrapped service member reports no drift — it reads the original', async () => {
  const wrapped = await cordisService()
  const warnings = await captureWarn(async () => {
    const port = commandPortOver(wrapped, fakeAgents())
    assert.deepEqual(await port.list('s'), [{ name: 'compact', description: 'compact 的说明' }])
    assert.deepEqual(await port.execute('s', '/compact'), { ok: true, commandId: 'cmd-1' })
  })
  // 读不出就报「变了」时，这两条永远响 —— 真正的漂移从此混在噪声里没人看得见。
  assert.deepEqual(warnings, [], warnings.join('\n'))
})
