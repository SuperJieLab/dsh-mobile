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

import { describeError, isNotFound } from '../ports/errors.ts'
import { createLogger, LogModule } from '../log.ts'
import type { WorkspacePort, WorkspaceSnapshot } from '../ports/workspace.ts'

const log = createLogger(LogModule.workspace)

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

/**
 * 本适配器用到的工作空间控制器写面 —— 宿主的公开入口，用它而不是自己组合
 * `resolveByPath` + `create`：**「这一次是不是新建的」只有它回答**（注册表那两个方法
 * 各自都不带这一格），而且它内部已经串行化了（`enqueue`），我们不必再实现一条队列。
 */
export interface WorkspaceCreateFace {
  create(request: { path: string }): Promise<{
    workspace: { workspaceId: string; title: string }
    created: boolean
  }>
}

/** 同一个控制器的删除面。拆成两个窄面：每个适配函数只声明自己用的那一个方法。 */
export interface WorkspaceDeleteFace {
  delete(request: { workspaceId: string }): Promise<{ deleted: true }>
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
    // **先来的那个胜出**（`has` 守住），不是后来的：参照界面找的是清单里**第一个**成员表
    // 含它的工作空间。正常数据下一个会话只属于一个组，两种写法同解；一旦注册表里出现重复
    // 成员（`attachSession` 只加不减，历史数据也可能被手改过），取后者会把同一批会话在
    // 手机与 Web UI 上分到不同的组 —— 而那正是这条判据要防的事。
    for (const sessionId of workspace.sessionIds) {
      if (!owners.has(sessionId)) owners.set(sessionId, workspace.id)
    }
    return { id: workspace.id, title: workspace.title }
  })
  return { rows, owners }
}

/**
 * 把一条已存在的路径注册成工作空间。
 *
 * 直接用宿主的控制器：它回答「这一次是不是新建的」（`created`），并在内部串行化 ——
 * 拿注册表的 `resolveByPath` + `create` 自己拼一遍，那两格与那条队列都要重写，
 * 而重写出来的判据迟早与宿主的不一样。
 *
 * @param controller - 宿主的工作空间控制器。
 * @param path - 已存在的目录（调用方先建好）。
 */
export async function createWorkspaceIn(
  controller: WorkspaceCreateFace,
  path: string,
): Promise<{ workspaceId: string; title: string; created: boolean }> {
  const { workspace, created } = await controller.create({ path })
  // `created` 是这条链唯一一次出现的「这一次到底建了没有」—— 界面据此说两句不同的话，
  // 日志里没有它就分不清「用户以为建了新的，其实命中了旧的」。
  log.info(`${created ? 'registered' : 'already registered'} "${path}" → ${workspace.workspaceId}`)
  return { workspaceId: workspace.workspaceId, title: workspace.title, created }
}

/**
 * 删掉一个工作空间的**注册**。目录与会话日志都留着 —— 那是宿主的语义，本函数不越权。
 *
 * 「它已经不在」不是失败：宿主的 `delete` 对未知 id 抛 `workspace/not-found`，而用户的
 * 意图是「让它不在列表里」—— 那已经是事实。吞掉它，其余一律冒泡。
 *
 * **仍然向宿主问一次**，即使本地记得它不存在：本地记忆会过期，而这一次调用本来就是廉价的。
 *
 * @param controller - 宿主的删除面。
 * @param workspaceId - 要解除注册的工作空间。
 */
export async function deleteWorkspaceIn(
  controller: WorkspaceDeleteFace,
  workspaceId: string,
): Promise<void> {
  try {
    await controller.delete({ workspaceId })
    log.info(`registration removed: ${workspaceId} (directory and sessions kept)`)
  } catch (error) {
    if (isNotFound(error)) {
      // 吞掉是对的（用户的意图已经达成），**静默吞不对**：用户说「我删了但组还在」时，
      // 这一行是唯一能证明「网关处理过、而且当时它已经不在了」的东西。
      log.info(`registration already gone: ${workspaceId} — treated as success`)
      return
    }
    log.warn(`removing registration ${workspaceId} failed: ${describeError(error)}`)
    throw error
  }
}
