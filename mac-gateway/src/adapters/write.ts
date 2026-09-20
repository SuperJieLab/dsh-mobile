/**
 * The write channel's adapters (M5): the approval relay and the prompt pump.
 *
 * **The relay (实施期修正 11).** The original design parked a host-side
 * waterfall listener; the running product proved that dead — `api-remotes`
 * sits earlier in the waterfall and parks every `approval/request` in
 * `pendingRemoteEvents` until a *remote client* answers (host-side responders
 * only see a request the remotes layer explicitly delegates). So the relay
 * makes this plugin what the browser is: a remote event-stream client. It
 * opens the gateway's `$events` stream in-process, forwards every
 * `approval/request` waterfall frame to the phone over our own mux connection
 * (a connection-level `approval` frame), and answers through
 * `dispatchRpc("$events/result")` when the phone taps. Phone and browser are
 * peers: both see the question, first answer settles the waterfall, the
 * loser's answer meets `unknown-approval` (fail-closed, Plan §3.3 决定 3).
 *
 * Questions the phone never saw (offline at ask time) are replayed on the
 * next phone connection: the relay keeps its pending set until the upstream
 * `cancel` frame arrives, and the WS adapter replays pending questions to
 * every newly connected client — the same catch-up semantics the gateway
 * applies to late browser clients (`openRemoteEvents`).
 *
 * One-shot by construction: a delivered answer removes the pending entry only
 * when the gateway accepted the result; a `cancel` frame clears it outright.
 * The relay never infers a durable grant: every delivery maps to the one-shot
 * vocabulary (`allowed-once` / `rejected`).
 *
 * The pump forwards prompts to the controller's `prompt` — the same door the
 * web UI uses (Plan §3.3 决定 9). `promptId` rides upstream as the request id,
 * where the controller itself de-duplicates re-admission.
 */

import {
  ReplayTable,
  outcomeOfDecision,
  type ApprovalAnswerMessage,
  type SessionPromptMessage,
} from '../seam/write.ts'

/** One frame of the gateway's `$events` wire stream, as far as the relay cares. */
export type UpstreamWireFrame =
  | { type: 'ready'; clientId: string; host?: unknown }
  | { type: 'waterfall'; event: string; eventId: string; agentId: string; request: unknown }
  | { type: 'cancel'; eventId: string }
  | { type: 'emit'; event: string; args: unknown }

/** The part of the gateway service the relay drives. */
export interface RemoteEventGatewayLike {
  openWireStream(
    endpoint: string,
    payload: { args: Record<string, never> },
    signal: AbortSignal,
  ): AsyncIterable<UpstreamWireFrame> | Promise<AsyncIterable<UpstreamWireFrame>>
  dispatchRpc(endpoint: string, payload: { args: unknown }, signal: AbortSignal): Promise<unknown>
}

/** What the relay pushes at connected phones — the WS adapter's broadcast face. */
export interface BroadcasterLike {
  broadcast(frame: unknown): void
}

/** What `answerApproval` maps onto — the upstream outcome vocabulary. */
export type DeliveredOutcome = 'allowed-once' | 'rejected'

/** One `approval/request` frame the relay is holding for the phone. */
interface HeldRequest {
  eventId: string
  toolName: string
  callId?: string
  reason?: string
}

/** Reconnect backoff for the `$events` stream, same shape as the follow client's. */
const RELAY_RECONNECT_MIN_MS = 500
const RELAY_RECONNECT_MAX_MS = 10_000

export class ApprovalRelay {
  readonly #gateway: RemoteEventGatewayLike
  readonly #broadcaster: BroadcasterLike
  readonly #pending = new Map<string, HeldRequest>()
  readonly #replay = new ReplayTable<'delivered' | 'unknown-approval'>()
  #clientId: string | undefined
  #abort: AbortController | undefined
  #lifetime: AbortSignal | undefined

  constructor(gateway: RemoteEventGatewayLike, broadcaster: BroadcasterLike) {
    this.#gateway = gateway
    this.#broadcaster = broadcaster
  }

  /**
   * Open the `$events` stream and run the relay loop until `lifetime` aborts
   * (plugin teardown). Never throws into the caller. The stream is treated
   * the way the follow client treats its transport: one generation ends, the
   * next begins after a capped backoff — a dead relay silently empties the
   * phone's approval view, so liveness is not optional.
   */
  start(lifetime: AbortSignal): void {
    this.#lifetime = lifetime
    void this.#run()
  }

  stop(): void {
    this.#abort?.abort()
  }

  /** Whether the relay currently holds a live `$events` client identity. */
  get ready(): boolean {
    return this.#clientId !== undefined
  }

  async #run(): Promise<void> {
    this.#abort = new AbortController()
    const signal = AbortSignal.any([this.#abort.signal, this.#lifetime ?? neverAborted()])
    let backoff = RELAY_RECONNECT_MIN_MS
    while (!signal.aborted) {
      try {
        // openWireStream is an async method (runtime lib/index.js:581): it
        // returns a Promise that resolves to the $events async generator.
        // Iterating the Promise itself throws the exact "not async iterable"
        // TypeError, so unwrap first.
        const stream = await this.#gateway.openWireStream('$events', { args: {} }, signal)
        for await (const frame of stream) {
          if (signal.aborted) return
          if (frame.type === 'ready') {
            this.#clientId = frame.clientId
            backoff = RELAY_RECONNECT_MIN_MS
            console.log(`[mac-gateway] approval relay ready (clientId ${frame.clientId})`)
            continue
          }
          if (frame.type === 'waterfall' && frame.event === 'approval/request') {
            this.#hold(frame)
            continue
          }
          if (frame.type === 'cancel') {
            this.#pending.delete(frame.eventId)
            this.#broadcaster.broadcast({ type: 'approval', payload: { kind: 'cancel', eventId: frame.eventId } })
            continue
          }
        }
        if (signal.aborted) return
        console.warn('[mac-gateway] approval relay stream ended; reconnecting')
      } catch (error) {
        if (signal.aborted) return
        console.error(`[mac-gateway] approval relay stream failed: ${describe(error)}; reconnecting`)
      }
      // The client identity died with the stream: the gateway re-delivers
      // every still-pending question to the next connection, so carrying the
      // old set across generations would replay answers already consumed.
      this.#clientId = undefined
      this.#pending.clear()
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, backoff)
        signal.addEventListener('abort', () => { clearTimeout(timer); resolve() }, { once: true })
      })
      backoff = Math.min(backoff * 2, RELAY_RECONNECT_MAX_MS)
    }
  }

  /** Park one question for the phone and push it at every connected client. */
  #hold(frame: Extract<UpstreamWireFrame, { type: 'waterfall' }>): void {
    const request = frame.request as { toolName?: unknown; callId?: unknown; reason?: unknown } | undefined
    const toolName = typeof request?.toolName === 'string' ? request.toolName : undefined
    if (toolName === undefined) return // not an approval-shaped request; not ours to interpret
    const held: HeldRequest = {
      eventId: frame.eventId,
      toolName,
      ...(typeof request?.callId === 'string' ? { callId: request.callId } : {}),
      ...(typeof request?.reason === 'string' ? { reason: request.reason } : {}),
    }
    this.#pending.set(frame.eventId, held)
    console.log(`[mac-gateway] approval relay holding "${held.toolName}" (${frame.eventId})`)
    this.#broadcaster.broadcast({
      type: 'approval',
      payload: { kind: 'request', eventId: held.eventId, toolName: held.toolName, ...(held.callId === undefined ? {} : { callId: held.callId }), ...(held.reason === undefined ? {} : { reason: held.reason }) },
    })
  }

  /** Questions still standing — what a freshly connected phone is replayed. */
  held(): HeldRequest[] {
    return [...this.#pending.values()]
  }

  /**
   * The wire side: deliver one answer through the gateway's result door,
   * replaying the first outcome for a retried `answerId` (W1) and refusing
   * anything that does not name a held question (W2).
   */
  async answerApproval(answer: ApprovalAnswerMessage): Promise<'delivered' | 'unknown-approval'> {
    return this.#replay.remember(answer.answerId, () => this.deliver(answer)).value
  }

  /** The actual one-time delivery. Runs inside `ReplayTable.remember`. */
  private async deliver(answer: ApprovalAnswerMessage): Promise<'delivered' | 'unknown-approval'> {
    if (this.#clientId === undefined || !this.#pending.has(answer.eventId)) {
      console.log(`[mac-gateway] answer for ${answer.eventId}: no held question — unknown-approval`)
      return 'unknown-approval'
    }
    await this.#gateway.dispatchRpc('$events/result', {
      args: {
        clientId: this.#clientId,
        eventId: answer.eventId,
        outcome: { kind: 'result', value: outcomeOfDecision(answer.decision) },
      },
    }, this.#lifetime ?? neverAborted())
    this.#pending.delete(answer.eventId)
    console.log(`[mac-gateway] delivered ${answer.decision} for ${answer.eventId}`)
    return 'delivered'
  }
}

/** A signal that never aborts, for the no-lifetime call paths. */
function neverAborted(): AbortSignal {
  const controller = new AbortController()
  return controller.signal
}

/** The part of the controller's prompt door this pump calls. */
export interface PromptControllerLike {
  prompt(request: {
    requestId: string
    sessionId: string
    mode: 'queue' | 'steer'
    content: readonly { type: 'text'; text: string }[]
  }, signal: AbortSignal): Promise<{ accepted: true }>
}

/**
 * What the pump reports to the protocol layer. `unknown-session` maps the
 * controller's not-found failure; anything else is not the client's to fix by
 * resending, so it becomes `internal-error` at the caller.
 */
export type PromptOutcome = 'accepted' | 'unknown-session'

/** Admit one prompt through the controller. Throws for non-not-found failures. */
export async function pumpPrompt(controller: PromptControllerLike, prompt: SessionPromptMessage): Promise<PromptOutcome> {
  // The running controller's prompt door takes a caller signal and reads it at
  // the entrance (`signal.throwIfAborted()`); the web UI passes its request
  // signal. We have no caller lifetime to hand over, so a generous timeout
  // stands in: admission is fast, and once the message is queued the turn
  // proceeds regardless.
  const signal = AbortSignal.timeout(30_000)
  try {
    await controller.prompt({
      requestId: prompt.promptId,
      sessionId: prompt.sessionId,
      mode: 'queue',
      content: [{ type: 'text', text: prompt.text }],
    }, signal)
    return 'accepted'
  } catch (error) {
    if (isRemoteError(error) && error.code === 'session/not-found') return 'unknown-session'
    throw error
  }
}

/** Structural RemoteError check — this module cannot import the host's class. */
function isRemoteError(error: unknown): error is { code: string } {
  return typeof error === 'object' && error !== null
    && (error as { isDSHRemoteError?: unknown }).isDSHRemoteError === true
    && typeof (error as { code?: unknown }).code === 'string'
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
