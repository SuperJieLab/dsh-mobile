/**
 * The DSH host's faces, as this gateway sees them: every narrow interface (`*Like`)
 * the host's real types force us to declare (they do not resolve outside the dsh
 * installation), and every `*Over(ctx)` factory that builds a gateway-side port
 * over the host services. The assembly (`index.ts`) only calls these factories.
 *
 * The casts here are deliberate: each service is asserted to the narrow shape the
 * consuming adapter declares and no further.
 */
import type { Context } from '@deepseek-ai/cordis'
import { usageSnapshotOf } from '../contract/usage.ts'
import type { WritePort } from '../contract/write-channel.ts'
import type { ModelPort } from '../contract/model-selection.ts'
import { createSessionPort, type ListSource, type ModelSelectionSource, type ModelSelectionView, type PersistenceLike } from './sessions.ts'
import type { FollowSource } from '../remote/ws.ts'
import { modelPortOver, type ModelControllerLike } from './model.ts'
import { callThrough, openStreamThrough, parameterNamesOf } from './call-through.ts'
import { ApprovalRelay, pumpPrompt, type PromptControllerLike, type RemoteEventGatewayLike, type UpstreamWireFrame } from './write.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.faces)

/**
 * The list path's sources, assembled from the host services — each mirrors one thing
 * the reference list does (docs/dev/plans/M1-consistency-delta.md §2.2): records from
 * the corpus (headers + liveness), values from the live projection for a running
 * session and the stored checkpoint for a cold one, liveness from the agent registry.
 *
 * Nothing here reads a log.
 */
export function listSourceOver(ctx: Context): ListSource {
  return {
    async records() {
      const records = await (ctx.sessionQuery as unknown as CorpusLike).listSessions()
      return records.map(record => ({ header: record.header, live: record.live }))
    },

    liveValues(sessionId) {
      const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
      if (session === undefined) return undefined
      return (ctx.sessionProjections as unknown as ProjectionsLike).cachedSnapshot(session)?.values
    },

    storedValues(header) {
      const cache = ctx.sessionProjectionCache as unknown as ProjectionCacheLike
      const snapshot = cache.cachedSnapshot(header) ?? cache.cachedPredecessorTitle(header)
      return snapshot?.values
    },

    isRunning(sessionId) {
      return (ctx.agents as unknown as AgentsLike).get(sessionId)?.status === 'running'
    },

    // A row without projections is still the right row, but degrading *quietly* kept
    // the cache-parameter drift below invisible until the phone showed a blank screen,
    // so the count goes to a log.
    onProjectionFailure: (failures, first) => {
      log.warn(
        `${failures} session row(s) served without projections — first failure: ${String(first)}`,
      )
    },
  }
}

/**
 * The follow stream's source, from the host's session controller. One cast to the narrow
 * face the pump uses (`FollowSource`); the controller exists only in the web-app bundle,
 * where cordis holds this plugin until it appears.
 */
/** The projection keys the occupancy reading is built from — named so the read
 * does not materialize views nothing consumes (M6). */
const OCCUPANCY_KEYS = ['contextPressure', 'contextBreakdown'] as const

export function streamSourceOver(ctx: Context): FollowSource {
  // The cast names the shape from `ws.ts` rather than re-spelling it: a second
  // copy here silently went stale once already (it missed `turnWindow`).
  const controller = ctx.sessionController as unknown as Pick<FollowSource, 'follow'>
  return {
    follow: (request, signal) => controller.follow(request, signal),
    occupancyOf: (sessionId) => {
      const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
      if (session === undefined) return undefined
      const read = ctx.sessionProjections as unknown as ProjectionsLike
      const snapshot = read.snapshot(session, OCCUPANCY_KEYS)
      return snapshot === undefined ? undefined : usageSnapshotOf(snapshot.values, snapshot.asOfSeq)
    },
    // The model baseline rides the opening (M7): same projection read as the
    // snapshot path, one moment earlier — the opening is the path a live session takes.
    modelOf: (sessionId) => modelSelectionViewOf(ctx, sessionId),
  }
}

/** The part of `ctx.sessionQuery` this module uses. */
interface CorpusLike {
  listSessions(): Promise<readonly { header: never; live: boolean }[]>
}

/** The part of `ctx.sessions` this module uses. */
interface SessionsLike {
  get(id: string): unknown
}

/** The part of `ctx.sessionProjections` this module uses. */
interface ProjectionsLike {
  /** The zero-I/O read the list path uses: already-materialized cells only, with a water
   * mark that is the *lowest* cached cut. Upstream `dsh-session-projection`
   * `cachedSnapshot` documents the values as hints that may trail the live session. */
  cachedSnapshot(session: unknown): ProjectionSnapshotLike | undefined
  /** One consistent cut over the registered units at the log's current water mark —
   * the read the occupancy frames use, whose `asOfSeq` must advance
   * (docs/dev/plans/M6-presentation-layer.md §3.1 决定 3). */
  snapshot(session: unknown, keys?: readonly string[]): ProjectionSnapshotLike | undefined
}

/** One cut of projection values, as both reads above return it. */
interface ProjectionSnapshotLike {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * The part of `ctx.sessionProjectionCache` this module uses. ⚠️ **Positional
 * drift hazard**: at the runtime this build depends on (0.1.7-alpha.2), the face is
 * `cachedSnapshot(meta, keys?)` / `cachedPredecessorTitle(meta)`
 * (dsh-session-projection-cache/lib/index.js:193,214) — the header alone carries the
 * lifecycle identity, and it is the *only* argument given here, as the runtime's own
 * listing does (dsh-api-session-controller/lib/index.js:1917). An older signature
 * carried an `inheritedEventCount` prefix; passing positionally against a drifted
 * face lands the argument in `keys` (docs/dev/plans/M1-consistency-delta.md 实施期修正 16).
 */
interface ProjectionCacheLike {
  cachedSnapshot(header: never): { asOfSeq: number; values: Readonly<Record<string, unknown>> } | undefined
  cachedPredecessorTitle(header: never): { asOfSeq: number; values: Readonly<Record<string, unknown>> } | undefined
}

/** The part of `ctx.agents` this module uses. */
interface AgentsLike {
  get(id: string): { status?: string } | undefined
}

/**
 * The `modelSelection` projection's wire view for one session — the one read both
 * the snapshot baseline (M7 T4) and the follow opening's `model` field serve from.
 * Absence (session not live) is honest — the field stays out rather than guessing
 * a default (决定 1/7).
 */
function modelSelectionViewOf(ctx: Context, sessionId: string): ModelSelectionView | undefined {
  const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
  if (session === undefined) return undefined
  const read = ctx.sessionProjections as unknown as ProjectionsLike
  const snapshot = read.snapshot(session, ['modelSelection'])
  const view = snapshot?.values.modelSelection
  if (typeof view !== 'object' || view === null) return undefined
  return view as ModelSelectionView
}

export function modelSelectionSourceOver(ctx: Context): ModelSelectionSource {
  return {
    of: (sessionId) => modelSelectionViewOf(ctx, sessionId),
  }
}

/**
 * The write channel as the protocol layer sees it (M5), from the host like every other source.
 *
 * `approval-answer` goes to the relay; `session-prompt` through the controller's prompt door,
 * with `session/not-found` folded to `unknown-session` and other upstream failures rethrown so
 * `handle` answers `internal-error`.
 */
export function writePortOver(ctx: Context, relay: ApprovalRelay): WritePort {
  return {
    answerApproval: (answer) => relay.answerApproval(answer),
    promptSession: async (prompt) => pumpPrompt(promptControllerOver(ctx), prompt),
  }
}

/**
 * The model channel as the protocol layer sees it (M7), over the same controller the
 * relay and the pump use. Absence is an assembly fact, so it is announced at assembly
 * (G2's no-silent-degradation rule) and the ops then answer `internal-error` envelopes
 * — a phone must never see a dead connection where a refusal was meant.
 */
export function modelChannelOver(ctx: Context): ModelPort | undefined {
  const controller = ctx.sessionController as unknown as Partial<ModelControllerLike> | undefined
  if (
    controller === undefined ||
    typeof controller.selectModel !== 'function' ||
    typeof controller.modelCatalog !== 'function'
  ) {
    log.warn('sessionController has no model face — model-catalog/model-select will refuse as internal-error')
    return undefined
  }
  return modelPortOver(controller as ModelControllerLike)
}

/**
 * 审批中继所驱动的网关服务切面。
 *
 * `ctx.typertGateway` 拿到的是被 traceable/严格视图包过的成员，
 * 异步生成器方法包装后不再可迭代（真机日志 `openWireStream is not a function or
 * its return value is not async iterable`）—— 用全局注册表 symbol
 * `Symbol.for('cordis.original')`（cordis 的 `originalOf` 逃生口）即可解出原始实例。
 *
 * 原始实例的**形参位置**也会变 —— 0.1.7 把 `uplink` / `peer` 插在 `signal`
 * 前，按位置传的取消信号落进 uplink 槽，`AbortSignal.any([undefined, ...])` 当场抛错
 * （真机日志 `signals[0] is not of type AbortSignal.`）。对策：收流优先走**声明面**
 * `wireStream.open`（types.d.ts:87）；缺席才碰私有 `openWireStream`，实参**按形参名**填
 * （`openStreamThrough`），形参表读不出（bind/native 包过）时按 arity 兜底并告警。
 */
export function gatewayOver(ctx: Context): RemoteEventGatewayLike {
  const view = ctx.typertGateway as unknown as Record<PropertyKey, unknown> | undefined
  if (view === undefined || typeof view !== 'object') {
    throw new Error('ctx.typertGateway is unavailable — the web profile did not provide the gateway service')
  }
  const raw = (typeof view[Symbol.for('cordis.original')] === 'object' && view[Symbol.for('cordis.original')] !== null
    ? view[Symbol.for('cordis.original')]
    : view) as Record<PropertyKey, unknown>

  const members = `openWireStream=${typeof raw.openWireStream}, wireStream=${typeof raw.wireStream}, dispatchRpc=${typeof raw.dispatchRpc}`
  const dispatchRpc = raw.dispatchRpc
  if (typeof dispatchRpc !== 'function') {
    // The answer door is the relay's whole reason to exist: missing it has to
    // surface at alignment time, not on the first tapped answer.
    log.error(`approval relay gateway members: ${members}`)
    throw new Error('ctx.typertGateway exposes no dispatchRpc — the approval relay cannot answer without it')
  }

  const declared = (typeof raw.wireStream === 'object' && raw.wireStream !== null ? raw.wireStream : undefined) as
    | { open?: unknown }
    | undefined
  const opening = typeof declared?.open === 'function' ? declared.open : raw.openWireStream
  if (typeof opening !== 'function') {
    log.error(`approval relay gateway members: ${members}`)
    throw new Error('ctx.typertGateway exposes neither wireStream.open nor openWireStream — approval relay cannot run')
  }
  const opener = opening as (...args: unknown[]) => Promise<AsyncIterable<unknown>>
  log.info(
    `approval relay gateway: ${opener === declared?.open ? 'wireStream.open (declared)' : 'openWireStream (private)'} + dispatchRpc`,
  )
  // The one argument the relay cannot work without is cancellation: if this
  // build spells it differently, say so here rather than in a reconnect loop.
  const names = parameterNamesOf(opener)
  if (names === undefined || !names.includes('signal')) {
    log.warn(
      `approval relay: the stream opener declares ${names === undefined ? 'no readable parameters' : `no \`signal\` (${names.join(', ')})`}; feeding it positionally, cancellation last. reads: ${Function.prototype.toString.call(opener).slice(0, 160)}`,
    )
  }

  return {
    // `$events` speaks the relay's own vocabulary, so the stream is typed as
    // such at this one boundary — the opener itself is untyped upstream.
    openWireStream: (endpoint, payload, signal) =>
      openStreamThrough(opener, { endpoint, payload, signal }) as Promise<AsyncIterable<UpstreamWireFrame>>,
    // Same reason as the opener: the answer door is a private member too, and
    // its parameters may move.
    dispatchRpc: (endpoint, payload, signal) => callThrough(dispatchRpc, { endpoint, payload, signal }),
  }
}

/** The broadcast face for the relay: the WS adapter's socket set does not exist until
 * the listener effect runs, so the relay gets a face to broadcast into right away and
 * the adapter connects itself later. */
export function broadcasterOver(): {
  broadcast(frame: unknown): void
  connect(sink: (frame: unknown) => void): void
} {
  let sink: ((frame: unknown) => void) | undefined
  return {
    broadcast: (frame) => sink?.(frame),
    connect: (fn) => { sink = fn },
  }
}

/** The part of `ctx.sessionController` the prompt pump calls. */
function promptControllerOver(ctx: Context): PromptControllerLike {
  return ctx.sessionController as unknown as PromptControllerLike
}
