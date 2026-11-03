/**
 * 权限适配器：目录怎么取、当前值怎么读、切一档怎么落地 —— 三件判定都在这里，
 * 三个取数动作由装配层以闭包交进来。
 *
 * 写路径**走 `/permission <preset>` 命令**，不直调预设服务的 `set()` —— 后者只 append 事件，
 * 而命令那条经 `ctx.approval.setPolicy(agent, policy)` 额外给模型插一条「策略变了」的提示，
 * 与 Web UI 完全同一条路。协议面只收预设名，拼命令行是这一层的事。
 *
 * **折叠不在这里也不在客户端。** 当前值是宿主算好的那一个名字；客户端拿不到沙箱模式
 * 与审批策略，因此没有第二份实现可言。
 *
 * 收闭包而不收服务对象：五个宿主服务（预设、命令、agent、会话、投影）的窄面由装配层
 * 声明一次，本模块只装判定，于是它的判据不需要五个假服务。
 */

import type { PermissionOption, PermissionPort, PermissionSelectOutcome } from '../ports/permission.ts'
import type { PermissionView } from '../wire/permission.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.permission)

/** 「对不上任何预设」的显示态。宿主与客户端各有一份同名判定，这里只用来过滤。 */
const CUSTOM_PRESET = 'custom'

/** 一次命令受理的形状 —— 只要那个号，够写一行日志。 */
export interface CommandAcceptance {
  commandId: string
}

/** 一次命令调用的三种结局。`no-agent` 与 `unparsable` 的补救不同，所以不并成一档。 */
export type CommandCall =
  | { kind: 'accepted'; commandId: string }
  | { kind: 'no-agent' }
  | { kind: 'unparsable' }

/** 本适配器要的三次取数与一次落地。 */
export interface PermissionSources {
  /** 目录里此刻能选的预设（宿主配置序）。 */
  options(): readonly PermissionOption[]
  /** 会话当前的预设名；会话不在或投影没注册时 `undefined`。 */
  currentOf(sessionId: string): string | undefined
  /** 把一整行交给宿主的命令系统（命令是 per-agent 的，所以带会话）。 */
  execute(sessionId: string, line: string): Promise<CommandCall>
}

/** 基于宿主权限服务与命令服务构建契约的权限端口。 */
export function permissionPortOver(sources: PermissionSources): PermissionPort {
  /** **`custom` 永不转发** —— 它是「对不上任何预设」的显示态，不是切换目标。
   * 上游今天不把它放进目录，这里过滤是为了它哪天变了也不传到手机。 */
  function options(): PermissionOption[] {
    return sources.options()
      .filter(option => option.value !== CUSTOM_PRESET)
      .map(option => ({
        value: option.value,
        name: option.name,
        ...option.description === undefined ? {} : { description: option.description },
      }))
  }

  return {
    async catalog(sessionId: string): Promise<PermissionView> {
      const current = sources.currentOf(sessionId)
      return {
        ...current === undefined ? {} : { current },
        options: options(),
      }
    },

    async select(sessionId: string, preset: string): Promise<PermissionSelectOutcome> {
      // 硬要求：先在目录里校验。少了这一句，这个 op 就是一条「发一行字」的通道 ——
      // 客户端传什么都会落到宿主的命令行解析上。
      if (!options().some(option => option.value === preset)) {
        return {
          ok: false,
          code: 'unknown-preset',
          message: `no preset "${preset}" in this deployment's permission catalog`,
        }
      }
      const line = `/permission ${preset}`
      const call = await sources.execute(sessionId, line)
      if (call.kind === 'no-agent') {
        return { ok: false, code: 'unknown-session', message: `no live session "${sessionId}"` }
      }
      // `unparsable` 是上游的「语法或名字解析不了」—— 目录里明明有这个名字却解析不出，
      // 说明两边的名单已经分叉，不能当成功。
      if (call.kind === 'unparsable') {
        return { ok: false, code: 'unknown-preset', message: `the host did not accept "${line}"` }
      }
      log.info(`permission preset "${preset}" accepted for "${sessionId}" (${call.commandId})`)
      // 受理后重读一次：回包里的值是宿主算的，不是把发出去的那份当答案。
      const current = sources.currentOf(sessionId)
      return { ...current === undefined ? { ok: true } : { ok: true, current } }
    },
  }
}
