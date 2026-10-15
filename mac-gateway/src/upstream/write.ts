/**
 * 写通道适配器：审批中继与 prompt 泵。
 *
 * **中继。** `api-remotes` 在 waterfall 中更早，把每个 `approval/request` 挂进
 * `pendingRemoteEvents` 等待*远程客户端*应答，因此中继把本插件变成一个远程
 * 事件流客户端 —— 打开网关的 `$events` 流，把每个 `approval/request` 帧作为
 * `approval` 帧转发给手机，并在点击时通过 `dispatchRpc("$events/result")`
 * 应答。手机与浏览器是对等方：第一个应答终结 waterfall，落败方得到
 * `unknown-approval`（fail-closed）。
 *
 * 手机从未见过的问题由 WS 适配器在下一次连接时重放；中继保持其待答集合直到
 * 上游 `cancel` 到达。构造上即一次性：已交付的应答只在网关接受后才移除待答项，
 * 且每次交付都映射到一次性词汇（`allowed-once` / `rejected`）——
 * 中继绝不推断持久授权。
 *
 * 泵把 prompt 转发给 controller 的 `prompt`（web UI 自己的门）；
 * `promptId` 即请求 id，controller 会去重。
 */

import { describeError, isNotFound } from '../contract/errors.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.relay)
import {
  ReplayTable,
  outcomeOfDecision,
  type ApprovalAnswerMessage,
  type ApprovalOutcome,
  type SessionPromptMessage,
} from '../contract/write-channel.ts'

/** 网关 `$events` 线上流的一帧，仅到中继关心的程度。 */
export type UpstreamWireFrame =
  | { type: 'ready'; clientId: string; host?: unknown }
  | { type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }
  | { type: 'cancel'; eventId: string }
  | { type: 'emit'; event: string; args: unknown }

/** 中继驱动的网关服务部分。 */
export interface RemoteEventGatewayLike {
  openWireStream(
    endpoint: string,
    payload: { args: Record<string, never> },
    signal: AbortSignal,
  ): AsyncIterable<UpstreamWireFrame> | Promise<AsyncIterable<UpstreamWireFrame>>
  dispatchRpc(endpoint: string, payload: { args: unknown }, signal: AbortSignal): Promise<unknown>
}

/** 中继推向已连接手机的内容 —— WS 适配器的广播切面。 */
export interface BroadcasterLike {
  broadcast(frame: unknown): void
}

/** 中继为手机暂存的一个 `approval/request` 帧。 */
interface HeldRequest {
  eventId: string
  toolName: string
  callId?: string
  reason?: string
}

/** `$events` 流的重连退避，形状与 follow 客户端相同。 */
const RELAY_RECONNECT_MIN_MS = 500
const RELAY_RECONNECT_MAX_MS = 10_000

export class ApprovalRelay {
  readonly #gateway: RemoteEventGatewayLike
  readonly #broadcaster: BroadcasterLike
  readonly #pending = new Map<string, HeldRequest>()
  readonly #replay = new ReplayTable<ApprovalOutcome>()
  #clientId: string | undefined
  #abort: AbortController | undefined
  #lifetime: AbortSignal | undefined

  constructor(gateway: RemoteEventGatewayLike, broadcaster: BroadcasterLike) {
    this.#gateway = gateway
    this.#broadcaster = broadcaster
  }

  /**
   * 打开 `$events` 流并运行中继循环，直到 `lifetime` 中止（插件拆除）。
   * 绝不抛错；一代结束、封顶退避后下一代开始 —— 存活不是可选项，死掉的中继
   * 会让手机的审批视图静默清空。
   */
  start(lifetime: AbortSignal): void {
    this.#lifetime = lifetime
    void this.#run()
  }

  /** 测试专用出口（生产 teardown 走 relayLifetime.abort()）。 */
  stop(): void {
    this.#abort?.abort()
  }

  /** 中继当前是否持有存活的 `$events` 客户端身份。 */
  get ready(): boolean {
    return this.#clientId !== undefined
  }

  async #run(): Promise<void> {
    this.#abort = new AbortController()
    const signal = AbortSignal.any([this.#abort.signal, this.#lifetime ?? neverAborted()])
    let backoff = RELAY_RECONNECT_MIN_MS
    while (!signal.aborted) {
      try {
        // openWireStream 是异步的（runtime lib/index.js:581）：直接迭代它返回的
        // Promise 会抛 "not async iterable"，所以先解包已 resolve 的生成器。
        const stream = await this.#gateway.openWireStream('$events', { args: {} }, signal)
        for await (const frame of stream) {
          if (signal.aborted) return
          if (frame.type === 'ready') {
            this.#clientId = frame.clientId
            backoff = RELAY_RECONNECT_MIN_MS
            log.info(`approval relay ready (clientId ${frame.clientId})`)
            continue
          }
          if (frame.type === 'waterfall' && frame.event === 'approval/request') {
            this.#hold(frame)
            continue
          }
          if (frame.type === 'cancel') {
            this.#pending.delete(frame.eventId)
            // 上游自己结算了这个问题（别处先答、或它被撤回）—— 这是「卡为什么消失」的唯一线索。
            log.info(`approval ${frame.eventId} was cancelled upstream`)
            this.#broadcaster.broadcast({ type: 'approval', payload: { kind: 'cancel', eventId: frame.eventId } })
            continue
          }
        }
        if (signal.aborted) return
        log.warn('approval relay stream ended; reconnecting')
      } catch (error) {
        if (signal.aborted) return
        log.error(`approval relay stream failed: ${describeError(error)}; reconnecting`)
      }
      // 客户端身份随流一起死掉：网关会重投每个仍在等待的问题，沿用旧集合
      // 会重放已消费的应答。
      this.#clientId = undefined
      this.#pending.clear()
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, backoff)
        signal.addEventListener('abort', () => { clearTimeout(timer); resolve() }, { once: true })
      })
      backoff = Math.min(backoff * 2, RELAY_RECONNECT_MAX_MS)
    }
  }

  /** 为手机暂存一个问题，并推给每个已连接的客户端。 */
  #hold(frame: Extract<UpstreamWireFrame, { type: 'waterfall' }>): void {
    const request = frame.request as { toolName?: unknown; callId?: unknown; reason?: unknown } | undefined
    const toolName = typeof request?.toolName === 'string' ? request.toolName : undefined
    if (toolName === undefined) return // 不是审批形状的请求；不归我们解释
    const held: HeldRequest = {
      eventId: frame.eventId,
      toolName,
      ...(typeof request?.callId === 'string' ? { callId: request.callId } : {}),
      ...(typeof request?.reason === 'string' ? { reason: request.reason } : {}),
    }
    this.#pending.set(frame.eventId, held)
    log.info(`approval relay holding "${held.toolName}" (${frame.eventId})`)
    this.#broadcaster.broadcast({
      type: 'approval',
      payload: { kind: 'request', eventId: held.eventId, toolName: held.toolName, ...(held.callId === undefined ? {} : { callId: held.callId }), ...(held.reason === undefined ? {} : { reason: held.reason }) },
    })
  }

  /** 仍在等待的问题 —— 新连接手机会被重放的内容。 */
  held(): HeldRequest[] {
    return [...this.#pending.values()]
  }

  /**
   * 线路侧：通过网关的结果门交付一个应答；重试的 `answerId` 重放首个结果（W1），
   * 未指向已暂存问题的一律拒绝（W2）。
   */
  async answerApproval(answer: ApprovalAnswerMessage): Promise<ApprovalOutcome> {
    return this.#replay.remember(answer.answerId, () => this.deliver(answer)).value
  }

  /** 实际的一次性交付。运行在 `ReplayTable.remember` 内部。 */
  private async deliver(answer: ApprovalAnswerMessage): Promise<ApprovalOutcome> {
    if (this.#clientId === undefined || !this.#pending.has(answer.eventId)) {
      log.info(`answer for ${answer.eventId}: no held question — unknown-approval`)
      return 'unknown-approval'
    }
    const reply = await this.#gateway.dispatchRpc('$events/result', {
      args: {
        clientId: this.#clientId,
        eventId: answer.eventId,
        outcome: { kind: 'result', value: outcomeOfDecision(answer.decision) },
      },
    }, this.#lifetime ?? neverAborted())
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

/** 永不中止的信号，供无 lifetime 的调用路径使用。 */
function neverAborted(): AbortSignal {
  const controller = new AbortController()
  return controller.signal
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
