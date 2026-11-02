/**
 * 装配边界：协议层要的「读工作空间」能力。
 *
 * 接口归**消费方**（协议层），所以住这里而不是传输层或适配层 —— 与
 * `session.ts` 同一理由：否则适配层要反过来 import 传输层去取一个类型。
 *
 * 手机端不知道这个接口存在：它是网关内部两层的约定，不是线上形状。
 */

import type { WorkspaceRow } from '../wire/rpc.ts'

/**
 * 一次读取得到的组清单与归属表。
 *
 * 两样出自**同一次**读取，所以它们之间不会有「清单里没有、归属里却有」这种
 * 半新半旧的状态。调用方拿一次、用两次（应答里的组清单、每行的归属）。
 */
export interface WorkspaceSnapshot {
  /** 按宿主的注册顺序 —— 那就是它的显示顺序，网关不重排。 */
  readonly rows: readonly WorkspaceRow[]
  /** 会话 id → 工作空间 id。不在表里 = 不属于任何工作空间。 */
  readonly owners: ReadonlyMap<string, string>
}

/** 协议层所依赖的数据源，用 fake 让测试摆脱运行时与文件系统。 */
export interface WorkspacePort {
  /** 同步：注册表在内存里，这个接口不该有等待。 */
  snapshot(): WorkspaceSnapshot
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
}

/** 一次创建工作空间的结果。 */
export interface WorkspaceCreated {
  workspaceId: string
  title: string
  /** `false` 表示这个名字已经在用，返回的是既有的那个 —— 不是失败。 */
  created: boolean
}
