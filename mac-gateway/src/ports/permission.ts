/**
 * 装配边界：两条权限 op 所依赖的能力，由宿主适配层实现。
 *
 * `PermissionSelectOutcome` 的两个码是**可归因的拒绝**：`unknown-preset` 表示这个名字
 * 不在宿主目录里（补救在客户端：重拉一次目录、改选一个），`unknown-session` 表示会话
 * 没有活着的 agent（切不了）。其余失败向上抛，由协议层折成 `internal-error`。
 */

import type { PermissionOption, PermissionView } from '../wire/permission.ts'

/** 一次 select 的结果：已受理，或那两类可归因的拒绝。 */
export type PermissionSelectOutcome =
  | { ok: true; current?: string }
  | { ok: false; code: 'unknown-preset' | 'unknown-session'; message: string }

/** 权限 op 所依赖的数据源 —— 契约的唯一依赖。 */
export interface PermissionPort {
  /**
   * 该会话此刻能选什么、现在是什么。
   *
   * `options` 缺席 = 这个装配没有权限服务；`current` 缺席 = 宿主不知道。
   * 两者都不猜默认值 —— 猜出来的档位会与 Web UI 显示的那个不一致。
   */
  catalog(sessionId: string): Promise<PermissionView>
  /**
   * 切到一档。
   *
   * `ok` **只表示宿主受理了** —— 落地证据是流里的 `permission/preset` 与随之的两个
   * knob 事件。回包里的 `current` 是受理后重读投影拿到的值，客户端据此显示。
   */
  select(sessionId: string, preset: string): Promise<PermissionSelectOutcome>
}

/** 目录里的一项 —— 与线上形状同形，转换层不做二次包装。 */
export type { PermissionOption, PermissionView }
