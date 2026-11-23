/**
 * 权限适配器：**只剩目录**。
 *
 * 三件事各有去处，都不在这里：
 * - 「这个会话现在是哪一档」在 `permissions` 投影里（`{currentValue}`），随 control 流到客户端；
 * - 「切一档」走 `commands/execute` 的 `/permission <preset>`（命令那条路经
 *   `ctx.approval.setPolicy` 额外给模型插一条「策略变了」的提示，与 Web UI 同一条）；
 * - 折叠（沙箱模式 + 审批策略 → 预设名）是宿主的判定，客户端拿不到那两个 knob。
 *
 * 留在这里的只有一件事：把宿主的目录交出去，并把 `custom` 摘掉 —— 它是「对不上任何预设」
 * 的显示态，不是能选的一项。
 */

import type { PermissionCatalog, PermissionOption } from '../wire/permission.ts'
import type { PermissionPort } from '../ports/permission.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.permission)

/** 「对不上任何预设」的显示态。宿主与客户端各有一份同名判定，这里只用来过滤。 */
const CUSTOM_PRESET = 'custom'


/** 本适配器要的一次取数：宿主声明的目录。 */
export interface PermissionSources {
  /** 宿主的目录原样（`PermissionCatalog`）：三个键都在。 */
  catalog(): PermissionCatalog
}

/** 基于宿主的预设服务构建契约的权限端口。 */
export function permissionPortOver(sources: PermissionSources): PermissionPort {
  return {
    async catalog(): Promise<PermissionCatalog | undefined> {
      const host = sources.catalog()
      // **`custom` 永不转发** —— 它是「对不上任何预设」的显示态，不是能选的一项。
      // 上游今天不把它放进目录，这里过滤是为了它哪天变了也不传到手机。
      const withoutCustom = (options: readonly PermissionOption[]): PermissionOption[] =>
        options
          .filter(option => option.value !== CUSTOM_PRESET)
          .map(option => ({
            value: option.value,
            name: option.name,
            ...option.description === undefined ? {} : { description: option.description },
          }))
      log.debug('permission catalog served', { options: host.options.length })
      return {
        options: withoutCustom(host.options),
        defaultOptions: withoutCustom(host.defaultOptions),
        defaultPreset: host.defaultPreset,
      }
    },
  }
}
