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

/** 本构建唯一使用的协议版本。 */
export const PROTOCOL_VERSION = 2

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
 * 会话列表的一行 —— 列表路径承诺的字段 (v2)。每个字段都来自会话头或
 * 已保留的投影，因此列表是零 I/O：这里没有任何东西需要读日志。
 * `updatedAt` 因此是「上次说话的时间」，不是「最新事件的时间」。
 */
export interface SessionRow {
  /** 已存储的会话 id。 */
  id: string
  /**
   * 当前标题。会话没有标题、或投影不可用时都缺省 —— 缺标题是契约
   * 的一部分，不是故障。
   */
  title?: string
  /** 会话创建时间的 Unix 纪元毫秒。 */
  createdAt: number
  /**
   * 最后一次用户 prompt 的 Unix 纪元毫秒；没有时取创建时间。**不是**最新
   * 事件的时间（v1 曾那样承诺，逼出一次日志读）。
   */
  updatedAt: number
  /** 该会话当前是否有 agent 在运行。 */
  running: boolean
  /** 会话是否还没有任何 turn。是否展示由客户端决定。 */
  blank: boolean
  /**
   * 本会话是另一会话的子会话时为 `'subagent'`，否则缺省。随行是为了让
   * 客户端自己应用参考 UI 的可见性规则 —— 服务端陈述事实，画不画仍归
   * 客户端。
   */
  origin?: string
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

/** 拒绝。`code` 是一个稳定的语义码（客户端按它决定重连、重翻还是放弃），
 * 不是给人看的句子 —— 句子在 `message` 里。 */
export interface WireError {
  code: string
  message: string
}

/** 任一成功应答。额外字段按 op 而定。 */
export interface OkResponse {
  v: typeof PROTOCOL_VERSION
  ok: true
  [field: string]: unknown
}

/** 任一被拒的应答。 */
export interface ErrorResponse {
  v: typeof PROTOCOL_VERSION
  ok: false
  error: WireError
}

/** 一条应答，成功或被拒。 */
export type Response = OkResponse | ErrorResponse
