/**
 * 两端共守的协议形状：一条线上消息进，一条线上消息出。
 *
 * 手机端有一份对应的 Swift 定义（`ios/Sources/Core/Gateway/Wire/` 下的形状，与
 * `ios/Sources/Core/Gateway/Rpc/Wire/RpcMessages.swift` 下的请求）——
 * **改这个文件的任何字段，那边必须同改**。这正是 `wire/` 存在的理由：把它与
 * 服务端算法放在一起时，读者无法从目录名判断「改它要不要动手机端」。
 *
 * 水位只有一个说法：打开帧的 `cursor` 与 `session/page` 的 `cursor`/`throughSeq`
 * **含端**（覆盖到的最后一个 seq），`beforeSeq` **排他**（这一页往前到哪）。
 * 「下一个期望的 seq」是客户端入口处的一次换算（`cursor + 1`），不进线上形状 ——
 * 两套口径并存时，任何一处 `±1` 漏掉都会让最后一条事件重复或丢失，而两者都不报错。
 */

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
