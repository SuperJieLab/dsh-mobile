/**
 * 工作空间写 op 的线上形状与请求判型。
 *
 * 两条都是转发：`workspace/create` 收 `{request:{path}}`（宿主按路径注册一个**已存在**的
 * 目录），`workspace/delete` 收 `{request:{workspaceId}}`。
 *
 * **没有名字规则**：F3 第 4 期起工作空间的标题由宿主从路径取，客户端不再输入名字，
 * 网关也不再判「这个名字能不能用」—— 那条规则曾经在两端各有一份，改一处另一处不会红。
 */

import { nonEmptyString, requestContainerOf } from './fields.ts'

/**
 * 请求 → 要注册的路径；形状不对、空串或纯空白时返回 `undefined`。
 *
 * 读的是宿主的 `request` 容器（`args.request.path`）—— 它的 `create(request)` 收一个对象，
 * 线上照抄这一层。少一层容器是旧客户端，按畸形拒。
 *
 * **不判这个路径是否存在、是不是绝对路径**：那是宿主的职责，它有自己的错误码
 * （`workspace/...`），在这里先判会让「目录不存在」表现成一个客户端载荷错误。
 *
 * @param args - `payload.args`。
 */
export function workspacePathOf(args: Record<string, unknown>): string | undefined {
  const request = requestContainerOf(args)
  if (request === undefined) return undefined
  const path = nonEmptyString(request.path)
  return path === undefined || path.trim() === '' ? undefined : path
}

/** `workspace-create` 的请求形状：只有一条宿主路径。 */
export interface WorkspaceCreatePayload {
  path: string
}

/** `workspace-delete` 的请求形状：只有一个工作空间 id。 */
export interface WorkspaceDeletePayload {
  workspaceId: string
}

/**
 * 请求 → 要删的工作空间 id；形状不对、空串或纯空白时返回 `undefined`。
 *
 * 读的是宿主的 `request` 容器（`args.request.workspaceId`）—— 它的 `delete(request)`
 * 收一个对象，线上照抄这一层。少一层容器是旧客户端，按畸形拒。
 *
 * 这里比 `nonEmptyString` 严一格（纯空白也拒）：工作空间 id 是宿主给的标识符，
 * 一个全是空白的 id 不可能指到任何东西。而拒绝的代价是零 —— 允许它的话，那次请求会
 * 一路走到宿主、得到 not-found、被适配层当成功吞掉，于是「载荷畸形」与「它本来就不在」
 * 在日志上完全同形。
 *
 * **不判它是否真的存在**：那是宿主的事，而删一个不存在的按成功处理 —— 在这一层先拦，
 * 会让「另一端已经删掉了」这件事表现成一个客户端错误。
 *
 * @param payload - 解析后的请求体，构造上形状未知。
 */
export function workspaceIdOf(args: Record<string, unknown>): string | undefined {
  const request = requestContainerOf(args)
  if (request === undefined) return undefined
  const workspaceId = nonEmptyString(request.workspaceId)
  return workspaceId === undefined || workspaceId.trim() === '' ? undefined : workspaceId
}
