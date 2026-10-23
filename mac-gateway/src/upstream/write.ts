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
import type { ApprovalSource, HeldApproval } from '../ports/approval.ts'
import type { ApprovalOutcome } from '../ports/write.ts'
import type { ApprovalAnswerMessage, SessionPromptMessage } from '../wire/write.ts'
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

export class ApprovalRelay implements ApprovalSource {
  /** 应答要带上的身份由它给出（身份属于源，不属于中继）。 */
  readonly #events: ForwardedEvents
  readonly #door: RemoteEventAnswerLike
  readonly #pending = new Map<string, HeldApproval>()
  /** 一条待答调用进来的听众 —— 每条开着的事件流各订一次。 */
  readonly #heldListeners = new Set<(held: HeldApproval) => void>()
  /** 一条被撤回的听众。 */
  readonly #cancelListeners = new Set<(eventId: string) => void>()
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
    lifetime: AbortSignal,
  ) {
    this.#events = events
    this.#door = door
    this.#lifetime = lifetime
    events.subscribe({
      generation: (generation) => {
        if (generation === undefined) this.#dropHeld()
      },
      frame: (frame) => this.#onFrame(frame),
    })
  }

  /**
   * 源这一代是否还活着。
   *
   * 没活着的身份，上游不认识我们的应答，也给不出一份可信的当前集合 —— 此时开流应当
   * 被拒绝（`source-unavailable`），而不是给一份「看起来有、其实不知道」的集合。
   */
  get ready(): boolean {
    return this.#events.clientId !== undefined
  }

  /** 订阅「一条待答调用进来了」。返回退订函数 —— 一条流关掉时它必须被调用。 */
  onHeld(listener: (held: HeldApproval) => void): () => void {
    this.#heldListeners.add(listener)
    return () => {
      this.#heldListeners.delete(listener)
    }
  }

  /** 订阅「一条被撤回了」。 */
  onCancelled(listener: (eventId: string) => void): () => void {
    this.#cancelListeners.add(listener)
    return () => {
      this.#cancelListeners.delete(listener)
    }
  }

  /** 上游来的一帧中，中继认得的那两种。 */
  #onFrame(frame: UpstreamWireFrame): void {
    if (frame.type === 'waterfall' && frame.event === 'approval/request') {
      this.#hold(frame)
      return
    }
    if (frame.type === 'cancel') {
      // 上游自己结算了这个问题（别处先答、或它被撤回）—— 这是「卡为什么消失」的唯一线索。
      if (this.#pending.delete(frame.eventId)) {
        log.info(`approval ${frame.eventId} was cancelled upstream`)
        for (const listener of this.#cancelListeners) listener(frame.eventId)
      }
    }
  }

  /**
   * 身份换代 = 待答表不再有效。宿主会把仍在等待的问题重投给下一代，所以这里只丢，
   * 不补发、也不通知手机 —— 每一条 `ready` 后面都跟着一份当前集合（新代重投的那些），
   * 客户端的表因此按代重建，不需要一条"集合空了"的帧。
   */
  #dropHeld(): void {
    const dropped = this.#pending.size
    this.#pending.clear()
    if (dropped > 0) log.info(`${dropped} held approval(s) dropped with the $events identity`)
  }

  /** 为手机暂存一个问题，并通知每条开着的流。 */
  #hold(frame: Extract<UpstreamWireFrame, { type: 'waterfall' }>): void {
    // 归属只有产生处知道。读不出就不收 —— 转发一条不知道属于谁的审批，等于让下游二选一：
    // 丢掉（等于没收到）或放进某一屏（等于串会话）。后者更坏，所以这里 fail closed。
    const agentId = nonEmptyString(frame.agentId)
    if (agentId === undefined) {
      log.warn(`approval ${frame.eventId} carries no session (agentId ${JSON.stringify(frame.agentId)}) — dropped`)
      return
    }
    const request = frame.request
    if (typeof request !== 'object' || request === null || Array.isArray(request)) {
      log.warn(`approval ${frame.eventId} carries no request object — dropped`)
      return
    }
    const held: HeldApproval = {
      event: frame.event,
      eventId: frame.eventId,
      agentId,
      request: request as Record<string, unknown>,
    }
    this.#pending.set(frame.eventId, held)
    log.info(`approval relay holding "${frame.event}" (${held.eventId}) for "${held.agentId}"`)
    for (const listener of this.#heldListeners) listener(held)
  }

  /** 仍在等待的问题 —— 每条流的 `ready` 之后要重放的内容。 */
  held(): HeldApproval[] {
    return [...this.#pending.values()]
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
