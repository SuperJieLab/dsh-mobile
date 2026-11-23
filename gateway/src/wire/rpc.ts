/**
 * 两端共守的协议形状：一条线上消息进，一条线上消息出。
 *
 * 手机端有一份对应的 Swift 定义（`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift`）——
 * **改这个文件的任何字段，那边必须同改**。这正是 `wire/` 存在的理由：把它与
 * 服务端算法放在一起时，读者无法从目录名判断「改它要不要动手机端」。
 *
 * 水位：两个边界均为半开。`since` 是客户端*下一个期望的 seq*（`0` = 「我什么都没
 * 有」）；`asOfSeq` 是「已覆盖到、不含」，并作为 `since` 回传，因此永远不会漏取或
 * 重取。两种不重叠的读取：`snapshot` 自 cursor 前向，`page` 反向取一个用于打开的
 * 窗口。
 *
 * 应答上限：单条应答 ≤ `maxDeltaEvents` 条事件，软性再受 `maxDeltaBytes` 约束；
 * 提前截停用 `hasMore` 说明。上限约束单条应答，从不是序列的累计。
 */

import type { ModelSelection } from './model.ts'

/**
 * 线上的一条会话事件：DSH 事件对象原样，未知字段一并保留。协议承诺下列
 * 字段存在，不承诺排他，客户端必须容忍未知字段。
 */
export interface WireEvent {
  /** DSH 事件类型，如 `user/message`。 */
  type: string
  /** 会话内单调递增的序号，从 0 连续。 */
  seq: number
  /** Unix 纪元毫秒。 */
  time: number
  /** 不透明载荷；协议层从不解读它。 */
  data: unknown
  [extraField: string]: unknown
}

/**
 * 一屏历史里的一条记录：事件外面包一层判别字段。
 *
 * 打开帧的 `records` 与分页应答的 `records` 是**同一个类型** —— 客户端用同一套合并
 * 逻辑吃它们，两处分开声明时，加一格只会在一边加。剥这一层是客户端的事。
 */
export interface SessionRecord {
  type: 'event'
  event: WireEvent
}

/**
 * 会话的元信息，随打开帧原样下发（上游 `SessionWireHeader`，九格）。
 *
 * 网关不解释其中的任何一格：`version` 的取值集合上游没有约定，`cwd`/`parentSession`
 * 只对宿主有意义。手机上用到哪几格是手机的判断，这里是转达。
 */
export interface SessionWireHeader {
  version: number
  id: string
  /** Unix 纪元毫秒。 */
  createdAt: number
  cwd?: string
  parentSession?: string
  /** 会话是否含一段 fork 继承来的前缀。 */
  isSeeded: boolean
  origin?: 'subagent'
  delegationDepth?: number
  agentPreset?: string
}

/**
 * 一次投影切取：值，以及它到达的水位。
 *
 * `session/control` 的 `baseline` 与打开帧随行的 `projections` 同形 —— 两者是同一份
 * 投影在两个出口上的样子，类型分开声明就会在一边漏一格。
 */
export interface ProjectionBaseline {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/** 一次读出的会话日志切片，以及它到达的水位。 */
export interface SessionSlice {
  /** 下一个期望的 seq —— 见上文的半开规则。 */
  asOfSeq: number
  /** `seq >= since` 的事件，按 seq 排序，至多请求的限额。 */
  events: readonly WireEvent[]
  /** 本切片之后日志是否还有事件。 */
  hasMore: boolean
  /**
   * 客户端的 cursor 指向一个不可能存在的位置：`since` 为正而日志为空。
   * 这是数据源唯一能证明的错误 cursor —— 越过水位的 `since` 会读成
   * 「已追平」。
   */
  staleCursor: boolean
  /**
   * 会话的模型基线：*下一个*请求将用的模型，读自宿主的
   * `modelSelection` 投影。未知时缺省 —— 客户端回退到目录默认值，
   * 绝不猜测。
   */
  model?: ModelSelection
}
