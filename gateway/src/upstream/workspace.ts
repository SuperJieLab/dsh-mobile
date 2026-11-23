/**
 * DSH 适配器：唯一知道工作空间控制器写面的模块。
 *
 * 只有两件事：把一条已存在的路径注册成工作空间，以及解除一个注册。**读面不在这里** ——
 * 组清单与归属由宿主的 `workspace/follow` 流给出（`upstream/faces.ts` 的
 * `workspaceFollowFace`），网关再自己折一遍就等于把同一件事做两遍，而两份判据迟早分叉。
 *
 * 形状在本文件自行声明，因为真实类型在 dsh 安装目录之外无法解析。
 */

import { describeError, isNotFound } from '../ports/errors.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.workspace)

/**
 * 本适配器用到的工作空间控制器写面 —— 宿主的公开入口，用它而不是自己组合
 * `resolveByPath` + `create`：**「这一次是不是新建的」只有它回答**（注册表那两个方法
 * 各自都不带这一格），而且它内部已经串行化了（`enqueue`），我们不必再实现一条队列。
 */
export interface WorkspaceCreateFace {
  create(request: { path: string }): Promise<{
    workspace: {
      workspaceId: string
      path: string
      title: string
      sessionIds: readonly string[]
      createdAt: string
      updatedAt: string
    }
    created: boolean
  }>
}

/** 同一个控制器的删除面。拆成两个窄面：每个适配函数只声明自己用的那一个方法。 */
export interface WorkspaceDeleteFace {
  delete(request: { workspaceId: string }): Promise<{ deleted: true }>
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
): Promise<{ workspace: Awaited<ReturnType<WorkspaceCreateFace['create']>>['workspace']; created: boolean }> {
  // 入参与应答都原样：宿主按路径注册，标题由它从路径取；我们只搬。
  const made = await controller.create({ path })
  // `created` 是这条链唯一一次出现的「这一次到底建了没有」—— 界面据此说两句不同的话，
  // 日志里没有它就分不清「用户以为建了新的，其实命中了旧的」。
  log.info(made.created ? 'workspace registered' : 'workspace already registered',
    { path, workspace: made.workspace.workspaceId })
  return made
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
    log.info('registration removed (directory and sessions kept)', { workspace: workspaceId })
  } catch (error) {
    if (isNotFound(error)) {
      // 吞掉是对的（用户的意图已经达成），**静默吞不对**：用户说「我删了但组还在」时，
      // 这一行是唯一能证明「网关处理过、而且当时它已经不在了」的东西。
      log.info('registration already gone — treated as success', { workspace: workspaceId })
      return
    }
    log.warn('removing registration failed',
      { workspace: workspaceId, error: describeError(error) })
    throw error
  }
}
