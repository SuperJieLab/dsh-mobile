/**
 * 写通道适配器：审批中继与 prompt 泵。
 *
 * **中继。** `api-remotes` 在 waterfall 中更早，把每个 `approval/request` 挂进
 * `pendingRemoteEvents` 等待*远程客户端*应答，因此宿主侧需要一个远程事件流客户端
 * 在场。那个身份归 `ForwardedEvents`（`remote-events.ts`，进程一份）；中继只是它的
 * 一个订阅者：把每个 `approval/request` 帧作为 `approval` 帧转发给手机，并在点击时
 * 通过 `dispatchRpc("$events/result")` 应答。手机与浏览器是对等方：第一个应答终结
 * waterfall，落败方得到 `unknown-approval`（fail-closed）。
 *
 * 手机从未见过的问题，由本层在每条新连接接入时给出要重投的帧序列（`replayFrames`），
 * 适配器只负责逐条送出；中继保持其待答集合直到上游
 * `cancel` 到达 —— 或者身份换代（源断了，宿主会把仍在等待的问题重投一遍，沿用旧
 * 集合就是重放已消费的应答）。构造上即一次性：已交付的应答只在网关接受后才移除
 * 待答项，且每次交付都映射到一次性词汇（`allowed-once` / `rejected`）——
 * 中继绝不推断持久授权。
 *
 * 泵把 prompt 转发给 controller 的 `prompt`（web UI 自己的门）；
 * `promptId` 即请求 id，controller 会去重。
 */

import { isNotFound } from '../ports/errors.ts'
import type { ApprovalOutcome } from '../ports/write.ts'
import type { ApprovalAnswerMessage, SessionPromptMessage } from '../wire/write.ts'
import type { MuxApprovalFrame, MuxApprovalPayload, MuxApprovalRequest } from '../wire/mux.ts'
import { nonEmptyString } from '../wire/fields.ts'
import type { UpstreamWireFrame } from '../ports/events.ts'
import type { ForwardedEvents } from './remote-events.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.relay)

/**
 * 网关应答门的窄切面 —— 中继唯一需要的上游能力。
 *
 * 开流不在这里：身份由 `ForwardedEvents` 持有，中继从它那里收帧。
 */
export interface RemoteEventAnswerLike {
  dispatchRpc(endpoint: string, payload: { args: unknown }, signal: AbortSignal): Promise<unknown>
}

/**
 * 中继推向已连接手机的帧 —— WS 适配器的广播切面。
 *
 * 收的是**审批帧**而不是任意帧：中继只推这一种，收宽了就等于放弃「构造漏字段」的
 * 编译期检查（`sessionId` 这种必填项只能在类型上守）。
 */
export interface BroadcasterLike {
  broadcast(frame: MuxApprovalFrame): void
}

/**
 * 中继为手机暂存的一个 `approval/request` 帧。
 *
 * 直接取线上形的 `request` 支去掉 `kind`：暂存的字段集合与要发出去的**必须是同一份**。
 * 抄一遍的话，「暂存里有、帧上没有」这种漏字段在评审里看不出来（两份声明相隔几十行、
 * 长得几乎一样），而症状只有重连重投之后才出现。
 */
type HeldRequest = Omit<MuxApprovalRequest, 'kind'>

export class ApprovalRelay {
  /** 应答要带上的身份由它给出（身份属于源，不属于中继）。 */
  readonly #events: ForwardedEvents
  readonly #door: RemoteEventAnswerLike
  readonly #broadcaster: BroadcasterLike
  readonly #pending = new Map<string, HeldRequest>()
  /** 存的是**这一次交付**（一个 Promise），不是它的结局 —— 重试的 `answerId` 因此共用同一次交付。 */
  readonly #replay = new ReplayTable<Promise<ApprovalOutcome>>()
  /** 应答门与中继同寿：插件拆除时一并取消在途交付。 */
  readonly #lifetime: AbortSignal

  /**
   * 构造即订阅：源上的一切通知从中继「在」的那一刻起就到它这里。
   *
   * `lifetime` 不是流的手柄（流归 `ForwardedEvents` 开），它只用来取消一次在途的
   * 应答交付 —— 上游的应答门要求一个真实的取消信号。
   */
  constructor(
    events: ForwardedEvents,
    door: RemoteEventAnswerLike,
    broadcaster: BroadcasterLike,
    lifetime: AbortSignal,
  ) {
    this.#events = events
    this.#door = door
    this.#broadcaster = broadcaster
    this.#lifetime = lifetime
    events.subscribe({
      generation: (generation) => {
        if (generation === undefined) this.#dropHeld()
      },
      frame: (frame) => this.#onFrame(frame),
    })
  }

  /** 上游来的一帧中，中继认得的那两种。 */
  #onFrame(frame: UpstreamWireFrame): void {
    if (frame.type === 'waterfall' && frame.event === 'approval/request') {
      this.#hold(frame)
      return
    }
    if (frame.type === 'cancel') {
      this.#pending.delete(frame.eventId)
      // 上游自己结算了这个问题（别处先答、或它被撤回）—— 这是「卡为什么消失」的唯一线索。
      log.info(`approval ${frame.eventId} was cancelled upstream`)
      this.#broadcaster.broadcast({ type: 'approval', payload: { kind: 'cancel', eventId: frame.eventId } })
    }
  }

  /**
   * 一个待答问题编码成线上那一帧 —— 实时与重投**共用这一处**。
   *
   * 两处各写一遍时，往一处加字段、另一处忘掉，测试看不出差别（两份代码长得几乎一样），
   * 而症状只有重连后才有。字段集合由 `HeldRequest` 与线上形同源保证，这里只补 `kind`。
   */
  #requestFrame(held: HeldRequest): MuxApprovalFrame {
    return { type: 'approval', payload: { kind: 'request', ...held } }
  }

  /**
   * 身份换代 = 待答表不再有效。宿主会把仍在等待的问题重投给下一代，所以这里只丢，
   * 不补发、也不通知手机（下一代的问题会作为新帧到达）。
   */
  #dropHeld(): void {
    const dropped = this.#pending.size
    this.#pending.clear()
    if (dropped > 0) log.info(`${dropped} held approval(s) dropped with the $events identity`)
  }

  /** 为手机暂存一个问题，并推给每个已连接的客户端。 */
  #hold(frame: Extract<UpstreamWireFrame, { type: 'waterfall' }>): void {
    const request = frame.request as { toolName?: unknown; callId?: unknown; reason?: unknown } | undefined
    const toolName = typeof request?.toolName === 'string' ? request.toolName : undefined
    if (toolName === undefined) return // 不是审批形状的请求；不归我们解释
    // 归属只有产生处知道。读不出就不收 —— 转发一条不知道属于谁的审批，等于让下游二选一：
    // 丢掉（等于没收到）或放进某一屏（等于串会话）。后者更坏，所以这里 fail closed。
    const sessionId = nonEmptyString(frame.agentId)
    if (sessionId === undefined) {
      log.warn(`approval ${frame.eventId} carries no session (agentId ${JSON.stringify(frame.agentId)}) — dropped`)
      return
    }
    const held: HeldRequest = {
      eventId: frame.eventId,
      sessionId,
      toolName,
      ...(typeof request?.callId === 'string' ? { callId: request.callId } : {}),
      ...(typeof request?.reason === 'string' ? { reason: request.reason } : {}),
    }
    this.#pending.set(frame.eventId, held)
    log.info(`approval relay holding "${held.toolName}" (${held.eventId}) for "${held.sessionId}"`)
    this.#broadcaster.broadcast(this.#requestFrame(held))
  }

  /** 仍在等待的问题 —— 新连接手机会被重放的内容。 */
  held(): HeldRequest[] {
    return [...this.#pending.values()]
  }

  /**
   * 一条新连接该收到的整段帧序列 —— 先对账、再逐条重投。
   *
   * 顺序是承诺：客户端先按 `sync` 把不在名单里的卡剪掉，再按 `request` 建卡。反过来
   * 送达的话，先建出来的卡会被紧随其后的名单剪掉，屏幕上闪一下。
   *
   * `stale` 的含义是「这份名单证明不了什么」：此刻没有存活的 `$events` 身份，我们不知道
   * 上游还挂着什么。那时只发一条标记为 stale 的空名单，**不重投** —— 宿主会把仍在等待
   * 的问题投给下一代，硬发一份旧集合就是在重放已经作废的投递。
   */
  replayFrames(): MuxApprovalFrame[] {
    // 没有存活的身份时待答表已被清空（源换代就丢），所以这一支的名单恒空。
    const live = this.#events.clientId !== undefined
    const held = this.held()
    const ledger: MuxApprovalPayload = {
      kind: 'sync',
      eventIds: held.map(item => item.eventId),
      // callIds 随行：客户端要靠它判断由日志重建的那些卡是不是悬空审计
      //（asked 之后宿主在询问中途死掉，decided 永远等不到）。
      callIds: held.flatMap(item => item.callId === undefined ? [] : [item.callId]),
      ...(live ? {} : { stale: true as const }),
    }
    return [
      { type: 'approval', payload: ledger },
      ...held.map(item => this.#requestFrame(item)),
    ]
  }

  /**
   * 线路侧：通过网关的结果门交付一个应答；重试的 `answerId` 重放首个结果，
   * 未指向已暂存问题的一律拒绝。
   */
  async answerApproval(answer: ApprovalAnswerMessage): Promise<ApprovalOutcome> {
    const { value } = this.#replay.remember(answer.answerId, () => this.deliver(answer))
    return value
  }

  /** 实际的一次性交付。运行在 `ReplayTable.remember` 内部。 */
  private async deliver(answer: ApprovalAnswerMessage): Promise<ApprovalOutcome> {
    // 身份不住了 ⇒ 上游无从认出这次应答，答案送不到任何地方。
    const clientId = this.#events.clientId
    if (clientId === undefined || !this.#pending.has(answer.eventId)) {
      log.info(`answer for ${answer.eventId}: no held question — unknown-approval`)
      return 'unknown-approval'
    }
    const reply = await this.#door.dispatchRpc('$events/result', {
      args: {
        clientId,
        eventId: answer.eventId,
        outcome: { kind: 'result', value: outcomeOfDecision(answer.decision) },
      },
    }, this.#lifetime)
    // 上游把失败**编码进返回值**而不是抛出 —— 不看它就区分不出「答上了」与
    // 「上游拒了」，而后者的现场是：我们还以为答完，轮次其实卡在原地等应答。
    const refusal = refusalOf(reply)
    if (refusal !== undefined) {
      log.error(`answer for ${answer.eventId} was refused by the gateway (${refusal}) — the question stays held, the turn is still waiting`)
      return 'undelivered'
    }
    this.#pending.delete(answer.eventId)
    log.info(`delivered ${answer.decision} for ${answer.eventId}`)
    return 'delivered'
  }
}

/**
 * 上游对一条应答的失败反馈；`undefined` = 它收下了。上游的 RPC 门把失败编码进返回值
 * （`{ok:false, error:{code,message}}`）而不是抛异常，所以「调用没炸」不构成「答上了」——
 * 判据必须落在返回值的形状上。
 */
export function refusalOf(reply: unknown): string | undefined {
  if (typeof reply !== 'object' || reply === null) return undefined
  const record = reply as Record<string, unknown>
  if (record.ok !== false) return undefined
  const error = record.error as Record<string, unknown> | undefined
  const code = typeof error?.code === 'string' ? error.code : 'unknown'
  const message = typeof error?.message === 'string' ? `: ${error.message}` : ''
  return `${code}${message}`
}

/** 本泵调用的 controller prompt 门部分。 */
export interface PromptControllerLike {
  prompt(request: {
    requestId: string
    sessionId: string
    mode: 'queue' | 'steer'
    content: readonly { type: 'text'; text: string }[]
  }, signal: AbortSignal): Promise<{ accepted: true }>
}

/**
 * 泵向协议层报告的内容：controller 的 not-found 失败映射为 `unknown-session`；
 * 其余任何失败都不是客户端重发能修的，在调用方变成 `internal-error`。
 */
export type PromptOutcome = 'accepted' | 'unknown-session'

/** 让一个 prompt 通过 controller 受理。非 not-found 失败会抛出。 */
export async function pumpPrompt(controller: PromptControllerLike, prompt: SessionPromptMessage): Promise<PromptOutcome> {
  // controller 的 prompt 门在入口读取调用方信号（`signal.throwIfAborted()`）；
  // web UI 传它的请求信号，而我们没有，所以用一个宽裕的超时代替：受理很快，
  // 排队后回合即继续。
  const signal = AbortSignal.timeout(30_000)
  try {
    await controller.prompt({
      requestId: prompt.promptId,
      sessionId: prompt.sessionId,
      mode: 'queue',
      content: [{ type: 'text', text: prompt.text }],
    }, signal)
    // 写链路的另一半（与 relay 的 delivered 对称）：受理即返回，回答从流里来。
    log.info(`prompt accepted for "${prompt.sessionId}" (requestId ${prompt.promptId}, ${prompt.text.length} chars)`)
    return 'accepted'
  } catch (error) {
    if (isNotFound(error)) return 'unknown-session'
    throw error
  }
}

/**
 * 记住每个幂等键的第一次结果，此后永远重放它：`produce` 每键至多运行一次，
 * 其副作用因此只发生一次。
 *
 * **幂等这条保证属于协议**：键是客户端铸造的 `answerId`（`wire/write.ts` 里写明
 * 「同键重试重放第一次的结果」），所以「重发得到同一个结论」是两端约定的一部分。
 * 这张表只是它的**实现** —— 手机端看不见表，但它依赖表的效果。
 *
 * 它住宿主适配层，理由是实现层面的：表里存的是 `ApprovalOutcome`（上游词汇，住
 * `ports/write.ts`），唯一消费者是 `ApprovalRelay`，而状态必须跟着交付它的中继走。
 * 放进 `protocol/` 会让 `upstream/` 必须 import `protocol/`，撞「宿主适配不认识判定层」。
 */
export class ReplayTable<V> {
  readonly #entries = new Map<string, V>()

  remember(key: string, produce: () => V): { value: V; fresh: boolean } {
    const existing = this.#entries.get(key)
    if (existing !== undefined) return { value: existing, fresh: false }
    const value = produce()
    this.#entries.set(key, value)
    return { value, fresh: true }
  }
}

/** 把客户端的两键词汇映射到上游的结论词汇。 */
export function outcomeOfDecision(decision: 'allow' | 'deny'): 'allowed-once' | 'rejected' {
  return decision === 'allow' ? 'allowed-once' : 'rejected'
}
