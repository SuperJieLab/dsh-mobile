/**
 * DSH 适配器：唯一知道工作空间注册表存在的模块。
 *
 * 它把注册表的实体翻成「组清单 + 归属表」两样东西。归属**按实体的成员表**给，
 * 不按目录路径比 —— 注册表自己已经按规范化后的目录建过索引（它的
 * `candidateMatches`），再比一遍等于把同一件事做两遍，而两份判据迟早分叉；
 * 客户端看到的组就会与 Mac 上的 Web UI 不一样。
 *
 * 形状在本文件自行声明，因为真实类型在 dsh 安装目录之外无法解析。
 */

import type { WorkspacePort, WorkspaceSnapshot } from '../ports/workspace.ts'

/** 本适配器读取的工作空间实体。成员表已由宿主按目录索引过滤过。 */
export interface WorkspaceLike {
  readonly id: string
  readonly title: string
  readonly sessionIds: readonly string[]
}

/** 本适配器用到的注册表部分。同步：持久顺序在内存里，不读盘。 */
export interface RegistryLike {
  list(): readonly WorkspaceLike[]
}

/** 本适配器用到的注册表写面。`create` 要求目录已存在，且对同一路径幂等。 */
export interface RegistryWriteLike {
  resolveByPath(path: string): Promise<{ id: string; title: string } | undefined>
  create(path: string): Promise<{ id: string; title: string }>
}

/**
 * 注册表 → 组清单与归属表。
 *
 * @param registry - 宿主的工作空间注册表。
 * @returns 保序的组清单，以及每个会话的归属；没有归属的会话不在表里。
 */
export function workspaceSnapshotOf(registry: RegistryLike): WorkspaceSnapshot {
  const workspaces = registry.list()
  const owners = new Map<string, string>()
  const rows = workspaces.map((workspace) => {
    for (const sessionId of workspace.sessionIds) owners.set(sessionId, workspace.id)
    return { id: workspace.id, title: workspace.title }
  })
  return { rows, owners }
}

/**
 * 把一条路径注册成工作空间，并回答「这一次是不是新建的」。
 *
 * 注册表自己的 `create` 是幂等的（同路径返回既有的那个），但它**不告诉你**这一次是新建
 * 还是命中，所以要先用 `resolveByPath` 问一次。两次调用之间的窗口由调用方串行化（见
 * `workspaceCreatorOver`）—— 不串行化时连点两下会让两次都报「新建了」，但不会造出两个
 * 工作空间：注册表那一层仍然幂等。
 *
 * @param registry - 宿主的注册表写面。
 * @param path - 已存在的目录（调用方先建好）。
 */
export async function registerWorkspace(
  registry: RegistryWriteLike,
  path: string,
): Promise<{ id: string; title: string; created: boolean }> {
  const existing = await registry.resolveByPath(path)
  if (existing !== undefined) return { ...existing, created: false }
  const workspace = await registry.create(path)
  return { ...workspace, created: true }
}
