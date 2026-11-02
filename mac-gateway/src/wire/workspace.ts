/**
 * 两个工作空间写 op 的线上形状与请求判型。
 *
 * 形状只有几格：`workspace-create` 的 `name` 与应答的 `workspaceId` / `title` / `created`；
 * `workspace-delete` 的 `workspaceId`。
 *
 * 判型与语义合在一次判断里 —— 对客户端而言两者的补救动作相同（改字重发 / 换一个组），
 * 分两个码只会让界面多一个分支。
 *
 * ⚠️ 名字规则在客户端有一份同样的实现（它要在提交前就拦下、不发请求）。两份靠同一组
 * 字面量对齐，改这里必须同步改 `WorkspaceName.swift`。
 */

import { nonEmptyString } from './fields.ts'

/** 名字里不许出现的两个路径分隔符。 */
const SEPARATORS = ['/', '\\']

/** `workspace-create` 的请求形状：只有一个名字。 */
export interface WorkspaceCreatePayload {
  name: string
}

/** `workspace-delete` 的请求形状：只有一个工作空间 id。 */
export interface WorkspaceDeletePayload {
  workspaceId: string
}

/**
 * 这个名字能不能当工作空间名。
 *
 * 判据是 trim 之后：非空、不含路径分隔符、不是 `.` 或 `..`。点开头（隐藏目录）是允许的 ——
 * 它是合法的目录名，没有理由拦。
 *
 * **不导出**：它只服务 `workspaceNameOf` 这一个 codec。对外只有一个答案 ——
 * 「这个名字能不能用」，由 codec 给。
 */
function isValidName(name: string): boolean {
  const trimmed = name.trim()
  return trimmed !== '' && trimmed !== '.' && trimmed !== '..'
    && !SEPARATORS.some(separator => trimmed.includes(separator))
}

/**
 * 请求 → 要用的名字（已 trim）；形状不对或名字不合法时返回 `undefined`。
 *
 * @param payload - 解析后的请求体，构造上形状未知。
 */
export function workspaceNameOf(payload: unknown): string | undefined {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  const name = nonEmptyString((payload as Record<string, unknown>).name)
  if (name === undefined) return undefined
  const trimmed = name.trim()
  return isValidName(trimmed) ? trimmed : undefined
}

/**
 * 请求 → 要删的工作空间 id；形状不对或 id 是空串时返回 `undefined`。
 *
 * **不判它是否真的存在**：那是宿主的事，而删一个不存在的按成功处理 —— 在这一层先拦，
 * 会让「另一端已经删掉了」这件事表现成一个客户端错误。
 *
 * @param payload - 解析后的请求体，构造上形状未知。
 */
export function workspaceIdOf(payload: unknown): string | undefined {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  return nonEmptyString((payload as Record<string, unknown>).workspaceId)
}
