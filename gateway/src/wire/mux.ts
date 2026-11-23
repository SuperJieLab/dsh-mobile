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
 * 这里**只有形状与编解码**。「这条打开装哪些事件」是宿主的事 —— 网关把 `snapshot`
 * 原样转达（`remote/stream.ts` 只按字节约束一次）。
 */

import type { ProjectionBaseline, SessionRecord, SessionWireHeader } from './rpc.ts'
import { nonEmptyString } from './fields.ts'
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
  | {
    type: 'ready'
    /**
     * 这条流在本进程里的名字 —— 应答审批时要把它带回去，网关据此判「这条流是谁的」。
     * 每条流现造一个，**换代不变**（换代不换流）：换 id 只会让重连那一瞬的在途应答白丢。
     */
    clientId: string
    /**
     * 宿主的工作目录，**原样透传**上游 `ready` 的 `host`。上游不给时这一格缺席（不是空串）。
     * 客户端本期不读它 —— 兑现的是「线上下发」这件事。
     */
    host?: { home: string }
  }
  | { type: 'emit'; event: string; args: readonly unknown[] }
  | MuxApprovalWaterfall
  | MuxApprovalCancel

/**
 * `session/control` 的货物 —— 与上游 `SessionControlFrame` 同形。
 *
 * **一条流装全部会话的投影**（上游是 Host-wide 的），不是单会话：`baseline` 给出每个
 * 会话的一次切取，之后的 `projection` 用 `sessionId` 指明是谁变了。
 * `changes` 里每项是 `{key, val}` —— 字段名是 `val`，不是 `value`，与上游逐字相同。
 */
export type ControlValue =
  | {
    type: 'baseline'
    value: { projections: Readonly<Record<string, ProjectionBaseline>> }
  }
  | {
    type: 'projection'
    sessionId: string
    /** 引发这次变化的那个事件的 seq —— 客户端据此排重与排序。 */
    seq: number
    changes: readonly { key: string; val: unknown }[]
  }

/**
 * 打开帧 —— 上游 `SessionFollowFrame` 的 `snapshot` 支，一个字段都不多不少。
 *
 * 网关**不再组装**它：窗口由宿主按自己的规则切，我们只转达。唯一的改动是字节收窄
 * （`records` 按轮截短、`hasMore` 改真），那是传输层的上界，不是窗口规则。
 *
 * `header` 与 `projections` 在宿主类型里是必填 —— 这里也必填。缺一格就是另一份形状，
 * 让它们可选只会让「上游漏发」在网关上看起来正常，而客户端整帧丢弃。
 */
export interface FollowSnapshot {
  type: 'snapshot'
  header: SessionWireHeader
  /** 打开覆盖到的最后一个 seq，**含端**（换算成「下一个期望」是客户端入口的事）。 */
  cursor: number
  records: readonly SessionRecord[]
  /** 窗口之前是否还有更旧的记录 —— 裁过就必须为真。 */
  hasMore: boolean
  projections: ProjectionBaseline
  assistantStream?: unknown
}

/**
 * `session/follow` 的货物 —— 三种，每种带自己的判别字段。
 *
 * 与 `EventsValue` / `ControlValue` 并列：三条流各自一张表，出货处用 `satisfies`
 * 让它生效。**没有一张跨三条流的总表** —— `MuxItemFrame.value` 在解析层是 `unknown`
 * （形状由端点决定，判在信封层等于把货物知识挪进来），总表也就没有消费方。
 */
export type FollowValue =
  | FollowSnapshot
  | { type: 'event'; event: unknown }
  | { type: 'assistant-stream'; frame: unknown }

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
 * 一条 `open` 帧要开的是**哪种**流 —— 端点表的判定结果。
 *
 * 与信封分两层判：`parseClientFrame` 只说「这是几号流」，这里说「这条流要什么」。
 * 认不出的端点因此不是畸形帧 —— 它归得上一条流，只是那条流开不起来（一条带编号的
 * `error` 帧，连接与别的流不动）。
 *
 * **四种流四个取值**：`events` 是上游的 `$events`，一条流承载四种货物（`ready` /
 * `emit` / `waterfall` / `cancel`）—— 原来按恢复语义拆出的三条流并回这里。
 * `workspace` 是组清单流，没有入参（组是进程级的，不分会话）。
 */
export type OpenRequest =
  | { kind: 'follow'; request: FollowRequest }
  | { kind: 'events' }
  | { kind: 'control' }
  | { kind: 'workspace' }

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
  // 请求**嵌一层**而不是摊平：摊平后那个 `kind` 会跟着请求一起被转给宿主，
  // 而宿主的形参只有 `SessionFollowRequest` 的那几个键 —— 多一格就是网关自己加的东西。
  return resolution.kind === 'follow'
    ? { kind: 'follow', request: resolution.request }
    : { kind: resolution.kind }
}

/** `payload.args` —— 端点方法的入参容器；载荷不是对象或没有 `args` 时视为缺席。 */
function argsOf(payload: unknown): unknown {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  return (payload as Record<string, unknown>).args
}
