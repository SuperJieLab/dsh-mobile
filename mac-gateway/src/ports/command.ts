/**
 * 装配边界：两条命令 op 所依赖的能力，由宿主适配层实现。
 *
 * `CommandExecuteOutcome` 的两个码是**上游的拒绝词汇**：`unknown-command` 表示那一行
 * 解析不出一个已注册的命令名（语法或名字不对，补救都在客户端：改字），
 * `unknown-session` 表示会话不在。其余失败向上抛，由协议层折成 `internal-error`。
 */

import type { CommandInfo } from '../wire/command.ts'

/** 一次 execute 的结果：已受理，或那两类可归因的拒绝。 */
export type CommandExecuteOutcome =
  | { ok: true; commandId: string }
  | { ok: false; code: 'unknown-session' | 'unknown-command'; message: string }

/** 命令 op 所依赖的数据源 —— 契约的唯一依赖。 */
export interface CommandPort {
  /**
   * 该会话此刻能用的命令。会话不在时返回 `undefined`。
   *
   * 「此刻」是字面意思：命令集是 per-agent 的，受作用域遮蔽与插件装卸影响，
   * 所以这里不缓存、也不承诺两次调用给同一份。
   */
  list(sessionId: string): Promise<readonly CommandInfo[] | undefined>
  /**
   * 把一整行交给宿主执行。
   *
   * `ok` **只表示受理** —— 宿主已经把 `command/run` 与 `command/done` 写进会话日志，
   * 结果从流里来。回包里没有、也不该有执行结果：两处都带就会出现「流里说失败、
   * 回包说成功」。
   */
  execute(sessionId: string, line: string): Promise<CommandExecuteOutcome>
}
