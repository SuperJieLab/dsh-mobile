/**
 * 命令适配器：唯一知道宿主命令系统怎么列、怎么执行的模块。
 *
 * 两个公开方法 `list(agent)` 与 `execute(agent, line, attachments, signal)` 是宿主的
 * Remote 门（`commands/src/index.ts` 的 `@Remote`），所以不需要私有切面逃生口；
 * 漂移风险在形参*列表*上，下面的签名检查盯着它（形参名变了要出声，绝不静默按位置喂垃圾）。
 *
 * **执行结果不在这里读。** 上游把结果同时写进日志（`command/run` / `command/done`），
 * 客户端从流里看；这里只回答「受理了没有」。把结果也带回去，就会出现两处说法不一致。
 *
 * 校验与语法归上游所有：一行字能不能解析成命令由它的 `parseCommand` 决定，
 * 我们只判「这是不是一条命令行」（`wire/command.ts`），不重写它的正则。
 */

import type { CommandExecuteOutcome, CommandPort } from '../ports/command.ts'
import type { CommandInfo } from '../wire/command.ts'
import { signatureNoteOf } from './call-through.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.command)

/**
 * 本适配器调用的命令服务部分。签名与运行时逐字一致 ——
 * 与真实切面不同的 fake 会让漂移通过所有测试。
 */
export interface CommandsLike {
  list(agent: unknown): readonly {
    name: string
    description: string
    input?: { hint: string; attachments?: boolean }
  }[]
  execute(
    agent: unknown,
    line: string,
    submittedAttachments: readonly never[],
    signal: AbortSignal,
  ): Promise<{ commandId: string } | undefined>
}

/** 会话注册表里 adapter 需要的那一格：按 id 取存活 agent。 */
export interface LiveAgentsLike {
  get(id: string): unknown
}

/** 执行一次的受理超时 —— 与 prompt 泵同款：受理很快，排上队之后回合自己继续。 */
const EXECUTE_TIMEOUT_MS = 30_000

/** 基于宿主的命令服务构建契约的命令端口。 */
export function commandPortOver(commands: CommandsLike, agents: LiveAgentsLike): CommandPort {
  // 组装期签名检查：下面的调用按位置传参，只要形参表与运行时一致就是精确的。
  // 变化在这里触发 —— 启动时，而不是第一次点击时。
  //
  // 读的是**宿主成员本身**（穿代理），不是 `commands.list` —— 后者是 cordis 的包装，
  // 源码读出来只有 `function () { [native code] }`，判成「变了」会让这条告警每次都响。
  for (const [member, expected] of [
    ['list', ['agent']],
    ['execute', ['agent', 'line', 'submittedAttachments', 'signal']],
  ] as const) {
    const note = signatureNoteOf(commands, member, expected)
    if (note !== undefined) log.warn(`command adapter: ${note} — calling positionally`)
  }

  return {
    async list(sessionId: string): Promise<readonly CommandInfo[] | undefined> {
      const agent = agents.get(sessionId)
      // 会话不存活 = 这份列表没有意义（不是空列表）：没有 agent 就没有 per-agent 的命令集。
      if (agent === undefined) return undefined
      return commands.list(agent).map(descriptor => ({
        name: descriptor.name,
        description: descriptor.description,
        // 只转达宿主声明的那一格；缺席就是缺席，不补空串。
        ...descriptor.input === undefined ? {} : { inputHint: descriptor.input.hint },
      }))
    },

    async execute(sessionId: string, line: string): Promise<CommandExecuteOutcome> {
      const agent = agents.get(sessionId)
      if (agent === undefined) {
        return { ok: false, code: 'unknown-session', message: `no live session "${sessionId}"` }
      }
      const execution = await commands.execute(agent, line, [], AbortSignal.timeout(EXECUTE_TIMEOUT_MS))
      // `undefined` 是上游的「语法或名字解析不了」—— 不是异常，也不是成功。
      if (execution === undefined) {
        return { ok: false, code: 'unknown-command', message: `no such command: ${line}` }
      }
      log.info(`command accepted for "${sessionId}" (${execution.commandId}): ${line}`)
      return { ok: true, commandId: execution.commandId }
    },
  }
}
