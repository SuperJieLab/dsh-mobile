/**
 * 装配边界：协议层要的「读会话」能力，由宿主适配层实现。
 *
 * 这些接口属于**消费方**（协议层），所以住在装配边界而不是传输层或适配层 ——
 * 后者若持有它们，适配层就得反过来 import 传输层去取一个类型。接口放这里，
 * 两边都只依赖它。
 *
 * 手机端不知道这些接口存在：它们是网关内部两层的约定，不是线上形状。
 */

import type { SessionRow, SessionSlice, WireEvent } from '../wire/rpc.ts'

/**
 * 协议层所依赖的数据源 —— 契约的唯一依赖；用 fake 让测试摆脱运行时、
 * 文件系统与网络。
 */
export interface SessionPort {
  /** 本进程可见的所有会话。顺序无意义。 */
  list(): Promise<readonly SessionRow[]>
  /**
   * 至多 `limit` 条 `seq >= since` 的事件；会话不存在时返回 `undefined`。
   * 切片自报是否还有剩余。
   */
  read(id: string, since: number, limit: number): Promise<SessionSlice | undefined>
  /**
   * 整条日志；会话不存在时返回 `undefined`。反向窗口需要日志末端，而存储
   * 读 API 只能自偏移处前向 —— 取整条日志是够到尾部的代价。列表路径不再
   * 付这个价（v2 读投影）；`page` 仍付。
   */
  readAll(id: string): Promise<readonly WireEvent[] | undefined>
}
