/**
 * 装配边界：协议层要的「读工作空间」能力（组流）与两条写 op。
 *
 * 接口归**消费方**（协议层），所以住这里而不是传输层或适配层 —— 与
 * `session.ts` 同一理由：否则适配层要反过来 import 传输层去取一个类型。
 *
 * 手机端不知道这个接口存在：它是网关内部两层的约定，不是线上形状。
 */

import type { WorkspaceFollowFrame } from '../wire/workspace-stream.ts'

/** 协议层所依赖的数据源，用 fake 让测试摆脱运行时与文件系统。 */
export interface WorkspacePort {
  /**
   * 在固定根下造出 `name` 这个目录，并把它注册成工作空间。
   *
   * 同名已经在用时**不是错误**：返回既有的那个，`created` 为假 —— 那正是用户想要的
   * （那个工作空间已经在那儿了）。要目录已存在才能注册是宿主的约束，所以这里先建目录。
   *
   * @param name - 已判过的名字（单段、非空、不含分隔符）。
   */
  create(name: string): Promise<WorkspaceCreated>
  /**
   * 解除一个工作空间的注册。**目录与会话日志都不动** —— 那一批会话从此没有归属，
   * 会落到「未分组」里。
   *
   * 删一个**已经不存在**的按成功处理：用户的意图是「让它不在列表里」，那已经是事实。
   * 报一个「没有这个东西」只会让人怀疑自己刚点的是什么，而重试本来就无害。
   *
   * ⚠️ **失败只经异常表达**（宿主的 `delete` 对未命中就是抛 `workspace/not-found`，
   * 它的返回值恒为 `{ deleted: true }`）。若宿主哪天改用「返回值里带 `false`」表达失败，
   * 这里会静默成功、客户端重拉后组还在而没有任何说法 —— 那时适配层必须跟着改。
   *
   * @param workspaceId - 已判过的 id（非空、非纯空白）；存在与否不在这里判。
   */
  delete(workspaceId: string): Promise<void>
  /**
   * 组流：打开时一条 `baseline`，之后六种增量，直到信号中止或宿主结束。
   *
   * **可选**：这条能力是宿主较新的切面，缺了不该让整个端口建不起来 —— 泵据此回一条
   * `internal-error`（与 `session/control` 的 `controlBaseline` 同一条拒绝路径）。
   * 不拒绝的代价是客户端等 45 秒开流超时，而超时判的是整条连接。
   *
   * 组清单与归属**同一次读**：`items[].sessionIds` 就是归属，不另取一份 —— 两份判据
   * 迟早分叉，客户端看到的组就会与 Mac 上的 Web UI 不一样。
   */
  follow?(signal: AbortSignal): AsyncIterable<WorkspaceFollowFrame>
}

/** 一次创建工作空间的结果。 */
export interface WorkspaceCreated {
  workspaceId: string
  title: string
  /** `false` 表示这个名字已经在用，返回的是既有的那个 —— 不是失败。 */
  created: boolean
}
