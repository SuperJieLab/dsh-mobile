/**
 * `directoryPicker/list` 的入参形状。
 *
 * `path` 可缺省（宿主的 `list(path: string | undefined, signal)`：缺省即 home）。缺省与
 * 「给了空串」是两件事：前者是合法的一种，后者是畸形载荷 —— 写路径从严的同一条纪律
 * 也适用这里，因为空串会被宿主读成相对路径，然后变成一个与用户意图无关的目录。
 */

import { nonEmptyString } from './fields.ts'

/** 校验通过的 `directoryPicker/list` 入参。 */
export interface DirectoryListArguments {
  /** 缺省 = 由宿主决定（它的 home）。 */
  readonly path?: string
}

/**
 * 解析 `directoryPicker/list` 的入参。
 *
 * 参数是**平铺的 `path`**（宿主的形参名），不是 `request` 容器。`path` 缺席合法；
 * 出现了就必须是非空字符串，否则整条 `undefined`。
 */
export function directoryListArgumentsOf(args: Record<string, unknown>): DirectoryListArguments | undefined {
  if (args.path === undefined) return {}
  const path = nonEmptyString(args.path)
  return path === undefined ? undefined : { path }
}
