/**
 * 两端共守的权限预设形状。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/PermissionMessages.swift`）—— 改字段那边必须同改。
 *
 * **线上只有目录，没有当前值，也没有沙箱模式与审批策略。**
 * - 当前值是会话级的事实，住在 `permissions` 投影里（`{currentValue}`），随
 *   `session/control` 到客户端。塞回目录应答就会出现「目录是新的、当前值是旧的」。
 * - 两个 knob 的折叠归宿主：客户端拿到它们就会自己算一遍，而「当前组合对不上任何预设」
 *   那条判定依赖「仍匹配的旧选择优先」这类规则，客户端只从事件推不出来。
 *
 * 切档也不在这里 —— 走 `commands/execute` 的 `/permission <preset>`，语法与名字校验
 * 都归宿主。本文件只剩目录的形状。
 */

/**
 * 一个可选的权限预设 —— 与上游 `PresetOption` 同形。
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
 * 目录应答 —— 与上游 `PermissionCatalog` 同形，三键都必需。
 *
 * `defaultPreset` 是**配置的默认档**，不是「当前档」：当前档在 `permissions` 投影里。
 * 客户端拿它只在「重拉期间不让格子闪成未知」时兜底。
 */
export interface PermissionCatalog {
  /** 此刻能选的（受集成与配置影响）。 */
  readonly options: readonly PermissionOption[]
  /** 装配声明的全部（不看当前集成）。 */
  readonly defaultOptions: readonly PermissionOption[]
  /** 没有会话级选择时生效的那个。 */
  readonly defaultPreset: string
}
