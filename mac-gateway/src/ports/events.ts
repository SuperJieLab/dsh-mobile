/**
 * 装配边界：协议层要的「这台机器上发生了什么」的能力。
 *
 * 接口归**消费方**，理由与 `follow.ts` 同一条：若它长在 `upstream/` 里，传输层的事件泵
 * 就得反过来认得宿主适配层。今天有两类消费方 —— 手机侧的事件流与审批中继 —— 它们订阅
 * **同一份**源（全仓只有一处 `$events` 身份）。
 *
 * `UpstreamWireFrame` 是**上游给出的帧形状**，不是两端约定的形状：手机端从来看不见它，
 * 网关把它折成两种 item 载荷才上线 —— 所以它不进 `wire/`。
 */

/** 网关 `$events` 线上流的一帧，仅到网关需要区分的程度。 */
export type UpstreamWireFrame =
  | { type: 'ready'; clientId: string; host?: unknown }
  | { type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }
  | { type: 'cancel'; eventId: string }
  | { type: 'emit'; event: string; args: unknown }

/**
 * 订阅者收到的两种通知。
 *
 * 分成两个方法而不是一个「事件联合」：`generation` 是**状态**（源的代次，会缺席），
 * `frame` 是**内容**（流上的帧）。消费方对二者的处置本来就不同 —— 审批只关心前者
 * 有没有（身份没了要丢掉待答表），事件泵要把后者转成 item。
 */
export interface ForwardedSink {
  /** 源的代次：每次上游 `ready` 加一；`undefined` = 源此刻没有活的代次。 */
  generation(generation: number | undefined): void
  frame(frame: UpstreamWireFrame): void
}

/**
 * 事件泵要的那一面：现在有没有代次，以及此后的一切通知。
 *
 * 订阅**不补发**当前状态 —— 需要「现在有没有代次」的消费方自己读 {@link generation}，
 * 那是它开流时必须做的一次读取（开口帧不许等源），不该伪装成一个迟到的事件。
 */
export interface ForwardedSource {
  readonly generation: number | undefined
  subscribe(sink: ForwardedSink): () => void
}
