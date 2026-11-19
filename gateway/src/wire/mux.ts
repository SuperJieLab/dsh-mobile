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
import type { ModelSelection } from './model.ts'
import { isPositiveInteger, nonEmptyString } from './fields.ts'
import { resolveEndpoint, type FollowRequest } from './endpoints.ts'

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
  /**
   * 这条流要开的是哪个端点 —— 信封层**不判**它，原样交给 `endpoints.ts` 的表。
   *
   * 判在这里就违反了「归得上一条流的事只归这条流」：名字不认识要回一条带编号的
   * `error`，而不是把整条连接关掉。所以这里只透传。
   */
  endpoint: unknown
  /** 端点方法的入参容器：`{ "args": … }`。上游的方法从 `args` 取参数，不是从载荷本身。 */
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
  /** 货物 —— 一支带判别字段的联合，形状由端点决定。 */
  value: unknown
}

/** 服务端 → 客户端：流正常结束。 */
export interface MuxEndFrame {
  type: 'end'
  streamId: StreamId
}

/** 服务端 → 客户端：流出错。 */
export interface MuxErrorFrame {
  type: 'error'
  streamId: StreamId
  /** 失败对象：三键恒定，`details` 是每个错误码自带结构化信息的地方。 */
  error: { code: string; message: string; details: Record<string, unknown> }
}

/**
 * 一条待答调用的字段，**不含 `kind`**。
 *
 * 单独一个名字让「暂存的字段」与「线上的字段」同源：中继存它、流泵给它补 `kind` 再发。
 * 它还解决另一件事 —— 判据按 `kind: '...'` 数构造点时，`Extract<T, …>` 这类**类型位置**
 * 会被算成第二个作者，给形状起个名字就不会。
 */
export interface MuxApprovalHeld {
  event: string
  eventId: string
  agentId: string
  request: Record<string, unknown>
}

/**
 * 一条待答调用 —— `$events` 流的一种货物（上游叫 `waterfall`）。
 *
 * 四个字段与上游 waterfall 帧逐字相同：这一层不解释载荷，只搬。`agentId` 就是会话身份，
 * 客户端按它入栏 —— 与它在上游的含义一致（`Agent.id` 即 `SessionId`）。
 */
export interface MuxApprovalWaterfall extends MuxApprovalHeld {
  type: 'waterfall'
}

/** 撤回一条待答调用 —— 唯一携带的寻址信息是 `eventId`。 */
export interface MuxApprovalCancel {
  type: 'cancel'
  eventId: string
}

/**
 * `$events` 流的货物 —— 四种，与上游 `RemoteEventFrame` 同形。
 *
 * 一条流装四种而不是四条流各装一种：上游就是这么分的，分派在客户端按 `type`
 * 与 `event` 名做。合并的代价是「审批源未就绪，整条流开不起来」，见泵上的注释。
 */
export type EventsValue =
  | { type: 'ready'; clientId: string }
  | { type: 'emit'; event: string; args: readonly unknown[] }
  | MuxApprovalWaterfall
  | MuxApprovalCancel

/**
 * `$control` 的货物 —— 投影的一次切取，与上游 `RemoteProjectionState` /
 * `RemoteProjectionPatch` 同形。
 *
 * `baseline` 是打开时的一次全量（客户端据此建表），`projection` 是一条增量
 * （`changes` 里每个键替换掉表里的同名格）。两种都带 `asOfSeq`：它是**投影**的水位，
 * 客户端按它比新旧 —— 乱序到达时旧值不许覆盖新值。
 */
export type ControlValue =
  | { type: 'baseline'; asOfSeq: number; values: Readonly<Record<string, unknown>> }
  | { type: 'projection'; asOfSeq: number; changes: readonly { key: string; value: unknown }[] }

export type MuxServerFrame = MuxItemFrame | MuxEndFrame | MuxErrorFrame

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

  if (frame.type === 'open') {
    return { type: 'open', streamId, endpoint: frame.endpoint, payload: frame.payload }
  }

  return undefined
}

/** 把一条服务端帧编码为线上文本。 */
export function encodeServerFrame(frame: MuxServerFrame): string {
  return JSON.stringify(frame)
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
 * 一条 `open` 帧要开的是**哪种**流 —— 端点表的判定结果。
 *
 * 与信封分两层判：`parseClientFrame` 只说「这是几号流」，这里说「这条流要什么」。
 * 认不出的端点因此不是畸形帧 —— 它归得上一条流，只是那条流开不起来（一条带编号的
 * `error` 帧，连接与别的流不动）。
 *
 * **三种流三个取值**：`events` 是上游的 `$events`，一条流承载四种货物（`ready` /
 * `emit` / `waterfall` / `cancel`）—— 原来按恢复语义拆出的三条流并回这里。
 */
export type OpenRequest =
  | ({ kind: 'follow' } & FollowRequest)
  | { kind: 'events' }
  | ({ kind: 'control' } & FollowRequest)

/** 端点表给出的两种拒绝 —— 调用方据此回一条带编号的 `error`，**不关连接**。 */
export type OpenRequestRefusal = { readonly error: 'unknown-endpoint' | 'invalid-args' }

/**
 * 把一条 `open` 帧校验为一条开流请求。
 *
 * @returns 请求本身，或两种拒绝之一。端点与参数都由 `endpoints.ts` 判 —— 这一层不
 *   再有自己的判据，免得多出一处「名字 → 泵」的映射。
 */
export function openRequestOf(frame: MuxOpenFrame): OpenRequest | OpenRequestRefusal {
  const resolution = resolveEndpoint(frame.endpoint, argsOf(frame.payload))
  if (!resolution.ok) return { error: resolution.code }
  switch (resolution.kind) {
    case 'events': return { kind: 'events' }
    case 'follow': return { kind: 'follow', ...resolution.request }
    case 'control': return { kind: 'control', ...resolution.request }
  }
}

/** `payload.args` —— 端点方法的入参容器；载荷不是对象或没有 `args` 时视为缺席。 */
function argsOf(payload: unknown): unknown {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  return (payload as Record<string, unknown>).args
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

