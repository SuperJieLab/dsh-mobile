/**
 * 两端共守的权限预设形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/PermissionMessages.swift`）—— 改字段那边必须同改。
 *
 * **线上只有预设名，没有沙箱模式与审批策略。** 那两个 knob 的折叠归宿主：客户端拿到
 * knob 就会自己算一遍，而「当前组合对不上任何预设」那条判定（宿主叫 `custom`）依赖
 * 「仍匹配的旧选择优先」这类规则，客户端只从事件推不出来。把 knob 发出去等于邀请第二份实现。
 *
 * 这里**只有形状与 `permission-select` 的解析**。目录怎么从宿主读、写怎么落到命令上
 * 住在 `upstream/permission.ts`。
 */

import { nonEmptyString } from './fields.ts'

/**
 * 一个可选的权限预设。
 *
 * `value` 是预设键（宿主配置里的名字，或集成注册的 `auto`）；`name` 是给人看的标签，
 * 宿主没配时就是键本身。客户端只在 `name === value` 时用自己的中文表，其余原样显示。
 */
export interface PermissionOption {
  value: string
  name: string
  /** 一句话说明它意味着什么；宿主没配就没有这个字段。 */
  description?: string
}

/**
 * 读 op 的应答：此刻能选什么、现在是什么。
 *
 * 两格都可以缺席，含义不同：
 * - `options` 缺席 = 这个装配没有权限服务（客户端据此不画那一格）；
 *   `options` 是空数组 = 服务在、但一项都没配。
 * - `current` 缺席 = 宿主不知道（会话不在、或投影没注册）—— 不是「默认档」。
 */
export interface PermissionView {
  current?: string
  options?: readonly PermissionOption[]
}

/** 校验通过的 `permission-select` 消息。 */
export interface PermissionSelectMessage {
  sessionId: string
  /** 预设键。不在宿主目录里的名字由网关拒，绝不落到命令上。 */
  preset: string
}

/**
 * 解析并校验一条 `permission-select` 载荷，不成形时返回 `undefined`。
 *
 * 只判「两个字段都是非空串」：**预设名合不合法由宿主的目录说了算**，不在这里维护
 * 第二份名单 —— 那份名单会在插件装卸后静默过期。
 */
export function permissionSelectRequestOf(
  message: Record<string, unknown>,
): PermissionSelectMessage | undefined {
  const sessionId = nonEmptyString(message.sessionId)
  const preset = nonEmptyString(message.preset)
  if (sessionId === undefined || preset === undefined) return undefined
  return { sessionId, preset }
}
