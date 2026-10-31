/**
 * 装配边界：协议层要的「读一条实时订阅」的能力。
 *
 * 接口归**消费方**（协议层），所以住在这里而不是传输层：宿主适配层要的是这个
 * 接口，若它长在传输层，适配层就得反过来 import 传输层 —— 依赖方向就反了。
 *
 * 两个类型同处一个端口：一个是能力声明（`FollowSource`），一个是**上游给出的
 * 帧形状**（`UpstreamFollowFrame`）。后者不是两端约定的形状 —— 手机端从来看不见
 * 它，网关把它解包成 mux 帧才上线 —— 所以它不进 `wire/`。
 */

import type { ModelSelection } from '../wire/model.ts'
import type { UsageSnapshot } from '../wire/usage.ts'

/**
 * 泵所用的宿主窄面，在此声明是因为各服务的真实类型在 dsh 安装树之外
 * 无法解析。follow 流与占用读数作为一次注入到达，因为两者出自同一宿主。
 */
export interface FollowSource {
  follow(
    request: {
      address: { kind: 'session'; sessionId: string }
      maxMessages?: number
      /**
       * 参考拼法的边界规则：一个可提前停下的下限与一个必须停下的上限
       * （见 `upstreamWindow`）。缺省即宿主仅按消息数切窗，窗口会在
       * 一轮中间打开。
       */
      turnWindow?: { minMessages: number; minTurns: number }
      assistantStream: true
    },
    signal: AbortSignal,
  ): AsyncIterable<UpstreamFollowFrame>
  /**
   * 立即读取一个会话的占用投影 —— 同步、内存内：宿主在事件落地时折叠
   * 投影，所以这是状态读，不是日志走查。
   *
   * @returns 读数；宿主不知道该会话时 `undefined`。
   */
  occupancyOf(sessionId: string): UsageSnapshot | undefined

  /**
   * 会话的模型基线：下一轮将用的那个选择，未知时 undefined（缺席不是「默认值」）。
   * 与窗口同一口气读出，手机打开时即知下一个请求用什么 —— HTTP snapshot
   * 带同一字段，但活会话实际走的是 follow 打开这条路。
   *
   * 出参是**选择本身**而非宿主的投影视图：类型在这里说不出来第二种形状，
   * 于是「把整份视图发出去」在编译期就不成立。
   */
  modelOf?(sessionId: string): ModelSelection | undefined
}

/**
 * 一次投影读取的基线与切点。
 *
 * `asOfSeq` 是**投影**的水位，与窗口的 `cursor` 是两条轴 —— 别相减、也别互相顶替。
 */
export interface ProjectionBaseline {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * 参考 follow 流的一帧：打开的 `snapshot`，其 `records` 把每条事件包成
 * `{type:'event', event}`；随后是同包裹的 `event` 帧；再后是无 cursor 的
 * `assistant-stream` 帧。
 */
export type UpstreamFollowFrame =
  | {
      type: 'snapshot'
      /** 打开覆盖的最后一个 seq，含端；空日志为 `-1`。 */
      cursor: number
      records: readonly { type: 'event'; event: unknown }[]
      /** 窗口之前是否还有更旧的事件（参考的 `hasMore`）。 */
      hasMore: boolean
      assistantStream?: unknown
      /**
       * 上游随打开送来的投影基线与切点（值已是各自的客户端视图）。
       *
       * 与窗口出自**同一次观察**，所以占用读数从这里算比经 `sessions.get` 更可靠：
       * 后者要一个已加载的会话对象，未激活的历史会话拿不到，占用会静默缺省。
       */
      projections?: ProjectionBaseline
    }
  | { type: 'event'; event: unknown }
  | { type: 'assistant-stream'; frame: unknown }
