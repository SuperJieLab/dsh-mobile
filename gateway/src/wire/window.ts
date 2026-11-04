/**
 * 两端共守的窗口几何。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift`）—— 改字段那边必须同改。
 *
 * 这里**只有形状**。怎么算出这个窗口（对齐轮次边界、上限与拒绝）是服务端的
 * 判定，住在 `protocol/window.ts` —— 手机端不重算它，也不该重算。
 */

import type { WireEvent } from './rpc.ts'

/** 一个反向窗口的几何 —— 由服务端的窗口算术产出。 */
export interface PageWindow {
  /** 窗口首个 seq（客户端回翻页时的下一个 `beforeSeq`）。 */
  pageStart: number
  /** 窗口到达的排他上界。 */
  asOfSeq: number
  /** 窗口之前是否还有更旧的事件。 */
  hasOlder: boolean
  /** 窗口的事件，按 seq 排序。 */
  events: readonly WireEvent[]
}
