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
}
