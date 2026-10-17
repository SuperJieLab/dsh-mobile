/**
 * 两端共守的 mux 成帧形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Contract/GatewayProtocol.swift` 与流通道的解码器）——
 * 改字段那边必须同改。
 *
 * 管辖一切非协议消息之物：帧信封（只有 `streamId`，别无其他）、follow 请求的
 * 形状。协议消息自 `rpc.ts` **原样** 通行。一条流就是一个 AsyncIterable ——
 * 无需关联。HTTP 信封的 `{v, op, ok}` 外壳不进流，因为流没有可标 ok 的应答；
 * 版本闸门在 `mux v1` 成帧契约里（"word for word"）。
 *
 * 这里**只有形状与编解码**。「这条打开装哪些事件」是传输层的事，由
 * `remote/stream.ts` 的泵从宿主给出的窗口装配。
 */

import type { WireEvent } from './rpc.ts'
import type { UsageSnapshot } from './usage.ts'
import type { ModelSelection } from './model.ts'

/** 客户端 → 服务端：开始一条逻辑流。 */
export interface MuxOpenFrame {
  type: 'open'
  streamId: number
  payload: unknown
}

/** 客户端 → 服务端：停止一条逻辑流。 */
export interface MuxCancelFrame {
  type: 'cancel'
  streamId: number
}

/** 客户端能在 mux 连接上发送的一切。 */
export type MuxClientFrame = MuxOpenFrame | MuxCancelFrame

/** 服务端 → 客户端：流的一项（打开、事件或 transient 帧）。 */
export interface MuxItemFrame {
  type: 'item'
  streamId: number
  payload: unknown
}

/** 服务端 → 客户端：流正常结束。 */
export interface MuxEndFrame {
  type: 'end'
  streamId: number
}

/** 服务端 → 客户端：流出错；`payload` 是协议的错误对象。 */
export interface MuxErrorFrame {
  type: 'error'
  streamId: number
  payload: { code: string; message: string }
}

/** 服务端 → 客户端：连接级 approval 推送。 */
export interface MuxApprovalFrame {
  type: 'approval'
  /** `{kind:'request', eventId, toolName, callId?, reason?}` 或 `{kind:'cancel', eventId}`。 */
  payload: unknown
}

/**
 * 服务端 → 客户端：一条流的占用读数 —— 流作用域，与 `approval` 不同：
 * 占用属于这条流所 follow 的会话。⚠️ 水位是投影的切点，不是窗口的
 * `cursor`，客户端不得拿两者相减。
 */
export interface MuxUsageFrame {
  type: 'usage'
  streamId: number
  /** 带 `sessionId`，供客户端核对帧是否属于自己打开的那条流。 */
  payload: { sessionId: string } & UsageSnapshot
}

/** 服务端能在 mux 连接上发送的一切。 */
export type MuxServerFrame = MuxItemFrame | MuxEndFrame | MuxErrorFrame | MuxApprovalFrame | MuxUsageFrame

/**
 * 从线上文本解析一条客户端帧。
 *
 * @returns 无法解析的 JSON、未知 `type`、非整数 `streamId`、`open` 载荷不是
 *   follow 请求 —— 一律返回 `undefined`，并以传输层 close 应对：解析不了的
 *   东西不是消息，也没有可拒收它的流。
 */
export function parseClientFrame(text: string): MuxClientFrame | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined
  const frame = parsed as Record<string, unknown>
  if (!isIntegral(frame.streamId)) return undefined

  if (frame.type === 'cancel') return { type: 'cancel', streamId: frame.streamId as number }

  if (frame.type === 'open') {
    return followRequestOf(frame.payload) === undefined
      ? undefined
      : { type: 'open', streamId: frame.streamId as number, payload: frame.payload }
  }

  return undefined
}

/** 把一条服务端帧编码为线上文本。 */
export function encodeServerFrame(frame: MuxServerFrame): string {
  return JSON.stringify(frame)
}

/**
 * `open` 载荷携带的 follow 请求 —— 刻意精简。参考请求是
 * `{address, maxMessages?, assistantStream?}`；显著的缺席者是水位：重连会重新
 * 打开并从新 opening 重建窗口，而不是从 cursor 续读。
 */
export interface FollowRequest {
  sessionId: string
  /** 打开的窗口大小；缺省即默认值，与 `page` 相同。 */
  maxMessages?: number
}

/**
 * 把 `open` 载荷校验为 follow 请求。
 *
 * op 集合与 HTTP 信封按名字与语义共享；follow 也走 mux 帧 —— 其他 op 或无 op，
 * 都不是 follow 请求。
 *
 * @returns 请求本身；命名不出会话时返回 `undefined` —— 与 `page` 相同的
 *   宽容边界：畸形 `maxMessages` 退化为默认值；没有可用 `sessionId` 就不是
 *   follow 请求。
 */
export function followRequestOf(payload: unknown): FollowRequest | undefined {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  const record = payload as Record<string, unknown>
  if (record.op !== 'follow') return undefined
  const sessionId = record.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') return undefined
  return isPositiveInteger(record.maxMessages)
    ? { sessionId, maxMessages: record.maxMessages as number }
    : { sessionId }
}

/** 打开帧的载荷：`page` 形状的窗口加上这条流的锚点。 */
export interface FollowOpening {
  sessionId: string
  /**
   * 打开被切下时日志已到达的排他上界 —— 其后的事件帧都从这一位置*之后*
   * 开始，客户端因此无需比对窗口内容即可断言「从这里起都是实时到达的」。
   */
  cursor: number
  /** 窗口首个 seq —— 客户端回翻页时的下一个 `beforeSeq`。 */
  pageStart: number
  /** 与 `page` 应答中的同名字段同义。 */
  hasOlder: boolean
  /** 窗口 —— 序列化方式与 `page` 应答的 `events` 完全一致。 */
  events: readonly WireEvent[]
  /**
   * transient 基线，活跃时原样随行：一个进行中的 assistant 尝试及其累计
   * 文本与下一个 chunk 序号。此处不透明 —— 语义归客户端的 `TransientChannel`
   * 所有；契约只承诺源给什么、到达时不变。
   */
  assistantStream?: unknown
  /**
   * 组装这条打开时读到的占用；投影无可显示之物时缺省 —— 是陈述，
   * 不是故障。
   *
   * ⚠️ `occupancy.asOfSeq` 是投影的切点，**不是**这条打开的 `cursor`：
   * 窗口按消息数切，可能落后或超前投影的日志 —— 两个独立水位。
   */
  occupancy?: UsageSnapshot
  /**
   * 这条会话下一轮将用的模型；源不知道时缺省 —— 与 `occupancy` 同为陈述，
   * 不是故障。语义是**选择本身**（`{provider, model, …}`），不是宿主的投影视图。
   *
   * 与 `snapshot` 应答里的同名字段同义、同值：两条出口读的是同一份投影
   * （`page` 不带这个字段 —— 它不读投影）。
   */
  model?: ModelSelection
}

/**
 * 调用方不指定时 follow 打开的窗口大小 —— 与 `page` 用同一个默认值，
 * 因为打开就是第一页。
 */
export const DEFAULT_FOLLOW_MESSAGES = 50

function isIntegral(value: unknown): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value)
}

function isPositiveInteger(value: unknown): boolean {
  return isIntegral(value) && (value as number) > 0
}
