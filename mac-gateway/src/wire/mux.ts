/**
 * 两端共守的 mux 成帧形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift` 与流通道的解码器）——
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
import { isPositiveInteger, nonEmptyString } from './fields.ts'

/**
 * 一条逻辑流的编号 —— **开流那一刻由客户端现造，此后不再复用**。
 *
 * 类型是字符串而不是数字，是为了让它没有可读含义：编号一旦能被解释（「1 是会话流、
 * 2 是审批流」），复用就跟着来 —— 而复用编号会让旧流的收尾删到新流的登记、旧流的
 * 残帧与新流同号。上游同样用不透明的 UUID 字符串（与端点无关的 mux 层）。
 *
 * 本层只判「非空」，不判格式：怎么造是客户端的事，网关只保证它非空且在一条连接内唯一。
 */
export type StreamId = string

/** 客户端 → 服务端：开始一条逻辑流。 */
export interface MuxOpenFrame {
  type: 'open'
  streamId: StreamId
  payload: unknown
}

/** 客户端 → 服务端：停止一条逻辑流。 */
export interface MuxCancelFrame {
  type: 'cancel'
  streamId: StreamId
}

/** 客户端能在 mux 连接上发送的一切。 */
export type MuxClientFrame = MuxOpenFrame | MuxCancelFrame

/** 服务端 → 客户端：流的一项（打开、事件或 transient 帧）。 */
export interface MuxItemFrame {
  type: 'item'
  streamId: StreamId
  payload: unknown
}

/** 服务端 → 客户端：流正常结束。 */
export interface MuxEndFrame {
  type: 'end'
  streamId: StreamId
}

/** 服务端 → 客户端：流出错；`payload` 是协议的错误对象。 */
export interface MuxErrorFrame {
  type: 'error'
  streamId: StreamId
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
  streamId: StreamId
  /** 带 `sessionId`，供客户端核对帧是否属于自己打开的那条流。 */
  payload: { sessionId: string } & UsageSnapshot
}

/** 服务端能在 mux 连接上发送的一切。 */
export type MuxServerFrame = MuxItemFrame | MuxEndFrame | MuxErrorFrame | MuxApprovalFrame | MuxUsageFrame

/**
 * 从线上文本解析一条客户端帧的**信封**：`type` 与非空 `streamId`。
 *
 * 只判到这一层。`open` 的 `payload` 是什么由 `openRequestOf` 在流这一层判 —— 分界就是
 * 「这一帧还能不能归到一条流上」：**归得上**（信封完好、编号在手），内容坏了只拒那条流
 * （一条带编号的 error 帧）；**归不上**（不是 JSON、缺编号、`type` 不认识），才以传输层
 * close 应对 —— 解析不了的东西不是消息，也没有可拒收它的流。
 *
 * @returns 归不到任何一条流时返回 `undefined`。
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
  const streamId = nonEmptyString(frame.streamId)
  if (streamId === undefined) return undefined

  if (frame.type === 'cancel') return { type: 'cancel', streamId }

  if (frame.type === 'open') return { type: 'open', streamId, payload: frame.payload }

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
  const sessionId = nonEmptyString(record.sessionId)
  if (sessionId === undefined) return undefined
  return isPositiveInteger(record.maxMessages)
    ? { sessionId, maxMessages: record.maxMessages }
    : { sessionId }
}

/**
 * 一条 `open` 帧要开的是**哪种**流 —— 载荷的判定结果。
 *
 * 与信封分两层判：`parseClientFrame` 只说「这是几号流」，这里说「这条流要什么」。
 * 认不出的 op 因此不是畸形帧 —— 它归得上一条流，只是那条流开不起来（一条带编号的
 * `unknown-op` error，连接与别的流不动）。
 *
 * 两种流的恢复语义不同（一条有窗口与水位，一条不重放），所以它们是两个取值而不是
 * 一个带可选字段的形状：可选字段会把「事件流没有会话」表达成「会话可能缺席」。
 */
export type OpenRequest = ({ kind: 'follow' } & FollowRequest) | { kind: 'events' }

/**
 * 把 `open` 载荷校验为一条开流请求。
 *
 * @returns 认不出的 op、或 follow 缺会话名时返回 `undefined` —— 调用方据此回一条
 *   带编号的 `unknown-op`，**不关连接**。
 */
export function openRequestOf(payload: unknown): OpenRequest | undefined {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  if ((payload as Record<string, unknown>).op === 'events') return { kind: 'events' }
  const follow = followRequestOf(payload)
  return follow === undefined ? undefined : { kind: 'follow', ...follow }
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

