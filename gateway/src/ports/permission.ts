import type { PermissionCatalog } from '../wire/permission.ts'

/**
 * 装配边界：权限目录所依赖的能力，由宿主适配层实现。
 *
 * **只剩读**：切档走 `commands/execute` 的 `/permission <preset>`（命令域），
 * 当前值走 `permissions` 投影（control 流）。这里再提供一条写路径，就等于让同一件事
 * 有两个入口，而两个入口的拒绝码迟早分叉。
 */

/** 权限目录所依赖的数据源 —— 契约的唯一依赖。 */
export interface PermissionPort {
  /**
   * 此刻能选什么、装配的默认档是什么。
   *
   * 返回 `undefined` = 这个装配没有权限服务（客户端据此不画那一格）；返回空数组的目录
   * = 服务在、一项都没配。两者在界面上不同，所以不在这里合成一种。
   *
   * **没有会话参数**：目录是进程级的；「这个会话现在是哪一档」在 `permissions` 投影里。
   */
  catalog(): Promise<PermissionCatalogValue | undefined>
}

/** 目录 —— 与线上形状同形，转换层不做二次包装。 */
export type PermissionCatalogValue = PermissionCatalog
