/**
 * 流契约的服务端部分：从整条日志装配一条 follow 打开。
 *
 * 帧形状、`follow` 请求的形状与它们的编解码都在 `wire/mux.ts`（两端共守，
 * 手机端有一份对应的 Swift 定义）；这里只剩**服务端才知道的那件事** —— 用哪个
 * 窗口函数把日志切成打开帧，以及它抛出的错误怎么被折成 `error` 帧。
 *
 * 打开与 `page` 共用 `pageWindow`，因此「打开就是 `page` 返回的同一个窗口」
 * 是结构保证。
 */

import { pageWindow } from './window.ts'
import { DEFAULT_FOLLOW_MESSAGES } from '../wire/mux.ts'
import type { FollowOpening, FollowRequest } from '../wire/mux.ts'
import type { WireEvent } from '../wire/rpc.ts'
import type { UsageSnapshot } from '../wire/usage.ts'

// 本文件不再声明这些形状与编解码，只重导出 —— 下游的 import 路径因此不必一次
// 改完（期2 搬算法时统一改成直连）。
export { DEFAULT_FOLLOW_MESSAGES, encodeServerFrame, followRequestOf, parseClientFrame } from '../wire/mux.ts'
export type {
  FollowOpening,
  FollowRequest,
  MuxApprovalFrame,
  MuxCancelFrame,
  MuxClientFrame,
  MuxEndFrame,
  MuxErrorFrame,
  MuxItemFrame,
  MuxOpenFrame,
  MuxServerFrame,
  MuxUsageFrame,
} from '../wire/mux.ts'

/**
 * 从一个会话的整条日志装配 follow 打开。
 *
 * 整日志输入与 `page` 同价（存储读 API 只能前向），这使窗口装配与 `page`
 * 完全一致：同一函数、同一稠密前置条件、同一边界规则。`occupancy` 按调用方
 * 读到的原样随行，窗口与状态出自同一时刻。
 *
 * @throws {@link pageWindow} 抛出的错误 —— 适配器把它们折成 `error` 帧，
 *   错误码与 `page` 拒绝时相同。
 */
export function followOpening(
  request: FollowRequest,
  events: readonly WireEvent[],
  occupancy?: UsageSnapshot,
): FollowOpening {
  const window = pageWindow(request.sessionId, events, undefined, request.maxMessages ?? DEFAULT_FOLLOW_MESSAGES)
  return {
    sessionId: request.sessionId,
    cursor: window.asOfSeq,
    pageStart: window.pageStart,
    hasOlder: window.hasOlder,
    events: window.events,
    ...(occupancy === undefined ? {} : { occupancy }),
  }
}
