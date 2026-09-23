/**
 * mac-gateway — the Mac-side DSH plugin for dsh-mobile.
 *
 * M0 Steps 2–3: own an HTTP listener on the LAN and answer the message
 * protocol on it. The listener is the transport; every protocol decision lives
 * in `rpc.ts` (a pure function this module only wires up), and every read of
 * the session store lives in `sessions.ts`.
 *
 * The list path (v2) is zero-I/O: it reads session headers plus a projection the
 * host already keeps, and never opens a session log. That needs four services
 * the base bundle provides, so all of them are declared in `inject` rather than
 * assumed — without them the fiber stays pending and the listener never starts,
 * which is the right failure: a gateway that cannot read sessions has nothing to
 * serve. See docs/dev/protocol.md §4.1 for why the list can be served this way.
 *
 * Runtime imports are deliberately limited to Node builtins plus our own
 * modules. This module lives outside the dsh installation, so a bare specifier
 * such as `@deepseek-ai/cordis` does NOT resolve from here (verified:
 * MODULE_NOT_FOUND — no `node_modules` exists in any parent directory). The
 * cordis import below is type-only and therefore erased by Node's type stripping.
 *
 * See docs/dev/plans/M0-reachability-spike.md §4.3 Steps 2–3 and docs/dev/protocol.md.
 */
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import { DEFAULT_LIMITS, handle, PROTOCOL_VERSION, type Limits, type SessionPort } from './contract/rpc.ts'
import type { WritePort } from './contract/write.ts'
import { usageSnapshotOf } from './contract/usage.ts'
import { createSessionPort, type ListSource, type PersistenceLike } from './adapters/sessions.ts'
import { attachStreamHandler, type FollowSource, type UpstreamFollowFrame } from './adapters/ws.ts'
import { CredentialVault, DEFAULT_CREDENTIALS_PATH } from './adapters/credentials.ts'
import { ApprovalRelay, callThrough, openStreamThrough, parameterNamesOf, pumpPrompt, type PromptControllerLike, type RemoteEventGatewayLike, type UpstreamWireFrame } from './adapters/write.ts'

/** Display metadata used by dsh diagnostics. */
export const name = 'mac-gateway'

/**
 * Services this plugin requires before it starts. Cordis holds the fiber until
 * they are available — see the module comment for why that is the honest
 * behaviour here rather than a fallback.
 */
export const inject = [
  // The read paths (snapshot / page) go straight to the stored log.
  'sessionPersistence',
  // The list path: records (headers + liveness), projections, and what is running.
  'sessionQuery',
  'sessionProjections',
  'sessionProjectionCache',
  'sessions',
  'agents',
  // The follow stream (M2): pump the controller's follow to the WS channel.
  // Only present in the web-app bundle — spec §8.5 B5 records what that costs.
  'sessionController',
  // The approval relay (M5, 实施期修正 11): the gateway's `$events` stream is
  // how a remote client receives and answers approval waterfall requests.
  'typertGateway',
]

/** Plugin config, supplied by the owning patch row. */
export interface Config {
  /** Bind address. `0.0.0.0` reaches the LAN; `127.0.0.1` is loopback only. @default '0.0.0.0' */
  host?: string
  /** Bind port. @default 3081 */
  port?: number
  /**
   * Most events one `snapshot` reply may carry. Config rather than a constant so
   * the caps are observable end to end (see docs/dev/protocol.md §五). @default 500
   */
  maxDeltaEvents?: number
  /** Soft ceiling on one reply's serialized `events`, in bytes. @default 1048576 */
  maxDeltaBytes?: number
  /**
   * Where the credentials file lives. Overridable so the assembly smoke tests
   * never touch the real home directory. @default '~/.dsh/dsh-mobile/credentials.json'
   */
  credentialsPath?: string
  /**
   * Pre-pair the vault with this device token (tests only). Production pairing
   * goes through the pairing code; this shortcut exists so an assembly test can
   * hold a token without parsing console output.
   */
  deviceTokenSeed?: string
}

/** All-interfaces bind: the whole point of M0 (see docs/dev/spec.md §四 M0). */
const DEFAULT_HOST = '0.0.0.0'

/** Deliberately not 3080 — that is the dsh web profile's own port. */
const DEFAULT_PORT = 3081

/**
 * Request-body ceiling. Not a protocol rule but a transport guard: the port is
 * reachable by anyone on the Wi-Fi, and an unbounded read is a trivial
 * memory-exhaustion lever. 1 MiB is far above any v2 request.
 */
const MAX_BODY_BYTES = 1_048_576

/**
 * Cordis calls this with the plugin's context and the config from its tree row.
 *
 * Host and port are config rather than constants so that switching the
 * reachability scheme stays a one-line patch edit — the reversibility claim in
 * §3.2 only holds while the bind address is not compiled in.
 */
export function apply(ctx: Context, config: Config = {}): void {
  const host = config.host ?? DEFAULT_HOST
  const port = config.port ?? DEFAULT_PORT
  const sessionPort = createSessionPort(
    ctx.sessionPersistence as unknown as PersistenceLike,
    listSourceOver(ctx),
  )
  // Caps are configuration, not constants: they exist to be lowered until a
  // chunked read is observable, which is exactly how they are verified.
  const limits: Limits = {
    maxDeltaEvents: config.maxDeltaEvents ?? DEFAULT_LIMITS.maxDeltaEvents,
    maxDeltaBytes: config.maxDeltaBytes ?? DEFAULT_LIMITS.maxDeltaBytes,
  }

  // The vault owns the three tickets (docs/dev/plans/M4-identity-credentials.md §4.2).
  // `pair` / `refresh` are answered before the auth gate — the gate exists to
  // protect everything *else* — and both carry their own credential in the body.
  const vault = new CredentialVault(config.credentialsPath ?? DEFAULT_CREDENTIALS_PATH)
  if (config.deviceTokenSeed !== undefined) {
    // Tests only: pre-pair without walking through the pairing code.
    vault.seedDeviceToken(config.deviceTokenSeed)
  }
  console.log(`[mac-gateway] pairing code (valid 10 min, one-shot): ${vault.pairingCode()}`)

  // The write channel (M5): the relay stands between `approval-answer` and the
  // gateway's `$events` stream as a remote event client (实施期修正 11 — the
  // host-side waterfall listener approach proved structurally dead); the pump
  // forwards `session-prompt` through the controller's own prompt door
  // (docs/dev/plans/M5-remote-intervention.md §四).
  const relayLifetime = new AbortController()
  const relay = new ApprovalRelay(gatewayOver(ctx), broadcasterOver())
  relay.start(relayLifetime.signal)
  const writePort = writePortOver(ctx, relay)

  console.log('[mac-gateway] plugin loaded — M5 build, auth on both channels, write channel on')

  ctx.effect(() => {
    const server = createServer((request, response) => {
      // `respond` never rejects; a throw here would be an unhandled rejection.
      void respond(request, response, sessionPort, limits, vault, writePort)
    })

    // The stream channel shares the listener: same port, `POST /rpc` for the
    // one-way calls, `/rpc/stream` upgrade for the follow stream. The upgrade
    // is gated like any request (M4): no live access token, no 101.
    const broadcaster = attachStreamHandler(server, streamSourceOver(ctx), vault, {
      // A freshly connected phone first gets the reconciliation frame — the
      // ids of every question still standing — then each one replayed. The
      // sync is what lets the client drop forwarded cards whose cancel frame
      // fired while it was offline (the gateway only delivers `cancel` to
      // clients that were connected at settle time, so an absent id on a
      // fresh connection is authoritative: that question is gone).
      onClientConnected: (send) => {
        const held = relay.held()
        if (!relay.ready) {
          // The relay has no live `$events` identity, so its held set proves
          // nothing. Say so: a `stale` sync tells the client to keep its
          // cards instead of pruning against an empty (lying) list.
          send({ type: 'approval', payload: { kind: 'sync', eventIds: [], callIds: [], stale: true } })
          return
        }
        send({
          type: 'approval',
          payload: {
            kind: 'sync',
            eventIds: held.map(h => h.eventId),
            // callIds ride along so the client can also reconcile its
            // audit-rebuilt cards (asked − decided in the log) against what
            // the gateway actually still holds: a dangling asked (host died
            // mid-ask, the decided never gets written) must not resurrect.
            callIds: held.flatMap(h => h.callId === undefined ? [] : [h.callId]),
          },
        })
        for (const heldItem of held) {
          send({ type: 'approval', payload: { kind: 'request', eventId: heldItem.eventId, toolName: heldItem.toolName, ...(heldItem.callId === undefined ? {} : { callId: heldItem.callId }), ...(heldItem.reason === undefined ? {} : { reason: heldItem.reason }) } })
        }
      },
    })
    approvalBroadcasterSink?.((frame) => broadcaster.broadcast(frame as Parameters<typeof broadcaster.broadcast>[0]))

    // console.* rather than ctx.logger: in our non-TTY verification runs
    // `ctx.logger.info` produced no stdout line at all (dsh's own startup line
    // was missing too), and a bind failure that cannot be seen is worse than a
    // non-idiomatic one. Whether the logger is merely TTY-gated is unverified —
    // see docs/dev/plans/M0-reachability-spike.md §5.1.
    server.on('error', (error) => {
      console.error(`[mac-gateway] listener error: ${String(error)}`)
    })

    server.listen(port, host, () => {
      console.log(`[mac-gateway] listening on http://${host}:${port}`)
    })

    return () => {
      relayLifetime.abort()
      // close() alone leaves idle keep-alive sockets open since Node 19, which
      // would keep the port occupied across a live patch reload.
      server.closeAllConnections()
      server.close()
    }
  }, 'mac-gateway.listener')
}

/**
 * The list path's sources, assembled from the host services.
 *
 * Each method mirrors one thing the reference list does (docs/dev/plans/M1-consistency-delta.md
 * §2.2): records come from the corpus (headers plus a liveness flag), values come
 * from the live projection for a running session and from the stored checkpoint
 * for a cold one, and liveness itself comes from the agent registry.
 *
 * Nothing here reads a log — that is the whole point. The casts are deliberate:
 * this module lives outside the dsh installation, where the service types are not
 * resolvable, so each service is asserted to the narrow shape the adapter
 * declares and no further.
 */
function listSourceOver(ctx: Context): ListSource {
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

    // A row without projections is still the right row — but degrading *quietly*
    // is how the cache-parameter drift below stayed invisible until the phone
    // showed a blank screen, so the count goes to a log the operator can read
    // (实施期修正 16).
    onProjectionFailure: (failures, first) => {
      console.warn(
        `[mac-gateway] ${failures} session row(s) served without projections — first failure: ${String(first)}`,
      )
    },
  }
}

/**
 * The follow stream's source, assembled from the host's session controller.
 *
 * One cast to the narrow face the pump uses (see `FollowSource`); the controller
 * is only present in the web-app bundle, where cordis holds this plugin until
 * it appears — the same honest wait the list path's services get.
 */
/**
 * The projection keys the occupancy reading is built from — named so the read
 * does not materialize views nothing consumes (M6).
 */
const OCCUPANCY_KEYS = ['contextPressure', 'contextBreakdown'] as const

function streamSourceOver(ctx: Context): FollowSource {
  const controller = ctx.sessionController as unknown as {
    follow(request: {
      address: { kind: 'session'; sessionId: string }
      maxMessages?: number
      assistantStream: true
    }, signal: AbortSignal): AsyncIterable<UpstreamFollowFrame>
  }
  return {
    follow: (request, signal) => controller.follow(request, signal),
    occupancyOf: (sessionId) => {
      const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
      if (session === undefined) return undefined
      const read = ctx.sessionProjections as unknown as ProjectionsLike
      const snapshot = read.snapshot(session, OCCUPANCY_KEYS)
      return snapshot === undefined ? undefined : usageSnapshotOf(snapshot.values, snapshot.asOfSeq)
    },
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
  /**
   * The zero-I/O read the list path uses: already-materialized cells only, and
   * a water mark that is the *lowest* cached cut (upstream
   * `dsh-session-projection`: `cachedSnapshot`, whose values may trail the live
   * session and are documented as hints).
   */
  cachedSnapshot(session: unknown): ProjectionSnapshotLike | undefined
  /**
   * One consistent cut over the registered units, cut at the log's current
   * water mark — the read the occupancy frames use, because their `asOfSeq`
   * must advance (docs/dev/plans/M6-presentation-layer.md §3.1 决定 3).
   */
  snapshot(session: unknown, keys?: readonly string[]): ProjectionSnapshotLike | undefined
}

/** One cut of projection values, as both reads above return it. */
interface ProjectionSnapshotLike {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * The part of `ctx.sessionProjectionCache` this module uses.
 *
 * ⚠️ **This face lost a parameter between the baseline and the runtime we run
 * against** (实施期修正 16). The baseline spells it
 *
 * ```ts
 * cachedSnapshot(meta: SessionHeader, inheritedEventCount: SessionLogOffset, keys?: …)
 * cachedPredecessorTitle(meta: SessionHeader, inheritedEventCount: SessionLogOffset)
 * ```
 *
 * and 0.1.7-alpha.2 spells it
 *
 * ```ts
 * cachedSnapshot(meta: SessionHeader, keys?: readonly string[])
 * cachedPredecessorTitle(meta: SessionHeader)          // dsh-session-projection-cache/lib/index.js:193,214
 * ```
 *
 * — the inherited prefix is gone because the header alone now carries the
 * lifecycle identity. Anything passed positionally after the header therefore
 * moves one slot, which is why the header is the *only* argument given here;
 * the runtime's own listing does the same
 * (`dsh-api-session-controller/lib/index.js:1917`). Passing a second argument
 * is not "more explicit", it is a bet on a position that has already moved once.
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
 * Route one request.
 *
 * `/rpc` carries protocol messages; everything else here exists only so a human
 * can tell "the listener is up" from "nothing is listening" with a browser.
 * Neither the liveness line nor the status codes are part of the protocol —
 * the envelope carries the outcome of a message, which is why a protocol-level
 * refusal is still HTTP 200.
 */
async function respond(
  request: IncomingMessage,
  response: ServerResponse,
  port: SessionPort,
  limits: Limits,
  vault: CredentialVault,
  writePort: WritePort,
): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://gateway').pathname

  if (path !== '/rpc') {
    // Liveness, and the answer to any unknown path. Transport-level only: no
    // protocol message is involved, so no envelope is involved either.
    response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(path === '/' ? 'mac-gateway alive — M4, protocol v2, POST /rpc for the protocol\n' : 'not found\n')
    return
  }

  if (request.method !== 'POST') {
    response.writeHead(405, { 'content-type': 'text/plain; charset=utf-8', allow: 'POST' })
    response.end('use POST /rpc\n')
    return
  }

  let body: string
  try {
    body = await readBody(request)
  } catch (error) {
    // Not a message at all, so it is refused as a transport failure rather than
    // answered with a protocol envelope carrying a meaningless code.
    response.writeHead(error instanceof TooLargeError ? 413 : 400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  let message: unknown
  try {
    message = JSON.parse(body)
  } catch (error) {
    response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  // Identity (M4): the auth ops carry their own credential in the body; every
  // other op needs a live access token. A denial is HTTP 401 with a protocol
  // envelope — the status codes the client keys its refresh flow on.
  const op = (message as { op?: unknown } | null)?.op
  if (op === 'pair' || op === 'refresh') {
    const answer = await handleAuthOp(op, message, vault)
    response.writeHead(answer.status, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(answer.body)}\n`)
    return
  }

  if (!vault.authenticate(request.headers.authorization)) {
    response.writeHead(401, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(refusal('unauthenticated', 'missing or expired access token — pair first, then refresh'))}\n`)
    return
  }

  const answer = await handle(message, port, Date.now, limits, writePort)
  // Write ops are the one place a refusal is not self-evident from the phone:
  // the client only shows a status line, so the server side keeps the evidence.
  if (!answer.ok && (op === 'session-prompt' || op === 'approval-answer')) {
    console.error(`[mac-gateway] write op "${op}" refused: ${JSON.stringify(answer.error)}`)
  }
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${JSON.stringify(answer)}\n`)
}

/** Refusal envelope shared by the auth path (the read path builds its own inside `handle`). */
function refusal(code: string, message: string): { v: number; ok: false; error: { code: string; message: string } } {
  return { v: PROTOCOL_VERSION, ok: false, error: { code, message } }
}

/**
 * The write channel as the protocol layer sees it (M5), assembled from the host
 * like every other source here.
 *
 * `approval-answer` goes to the relay; `session-prompt` goes through the
 * controller's prompt door, with `session/not-found` folded into the protocol's
 * `unknown-session` and every other upstream failure rethrown so `handle`
 * answers `internal-error` — conditions a retry cannot fix are our side's to
 * explain, not the client's to guess at.
 */
function writePortOver(ctx: Context, relay: ApprovalRelay): WritePort {
  return {
    answerApproval: (answer) => relay.answerApproval(answer),
    promptSession: async (prompt) => {
      try {
        return await pumpPrompt(promptControllerOver(ctx), prompt)
      } catch (error) {
        // Diagnostic (2026-09-19): the phone only sees `internal-error`; the
        // stack here is the evidence. Remove once the cause is fixed.
        console.error('[mac-gateway] prompt pump threw:', error)
        throw error
      }
    },
  }
}

/**
 * The part of the gateway service the approval relay drives.
 *
 * 实施期修正 13（真机日志 `openWireStream is not a function or its return
 * value is not async iterable`）：`ctx.typertGateway` 交到插件手里的不是
 * 服务原始实例 —— 每个成员可能被 traceable/严格视图包过一层，异步生成器
 * 方法经包装后不再返回可迭代对象。`Symbol.for('cordis.original')` 是全局
 * 注册表 symbol（cordis 的 `originalOf` 逃生口），无需 import 即可解出原始
 * 实例。
 *
 * 实施期修正 15（真机日志 `signals[0] is not of type AbortSignal.`）：拿到
 * 原始实例还不够 —— 收流面的**形参位置**会变。0.1.7 把 `uplink` / `peer`
 * 插在了 `signal` 前面，按位置传的取消信号落进 uplink 槽，网关内部
 * `AbortSignal.any([undefined, ...])` 当场抛错。两条对策：
 * 1. 收流优先走**声明面** `wireStream.open`（types.d.ts:87，有注释的 carrier
 *    适配口），只在它缺席时才碰私有成员 `openWireStream`；
 * 2. 实参一律**按形参名**填（`openStreamThrough`）—— 位置随便挪，名字不会。
 *    读不出形参表（被 bind/native 包过）时按 arity 兜底并显式告警。
 */
function gatewayOver(ctx: Context): RemoteEventGatewayLike {
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
    console.error(`[mac-gateway] approval relay gateway members: ${members}`)
    throw new Error('ctx.typertGateway exposes no dispatchRpc — the approval relay cannot answer without it')
  }

  const declared = (typeof raw.wireStream === 'object' && raw.wireStream !== null ? raw.wireStream : undefined) as
    | { open?: unknown }
    | undefined
  const opening = typeof declared?.open === 'function' ? declared.open : raw.openWireStream
  if (typeof opening !== 'function') {
    console.error(`[mac-gateway] approval relay gateway members: ${members}`)
    throw new Error('ctx.typertGateway exposes neither wireStream.open nor openWireStream — approval relay cannot run')
  }
  const opener = opening as (...args: unknown[]) => Promise<AsyncIterable<unknown>>
  console.log(
    `[mac-gateway] approval relay gateway: ${opener === declared?.open ? 'wireStream.open (declared)' : 'openWireStream (private)'} + dispatchRpc`,
  )
  // The one argument the relay cannot work without is cancellation: if this
  // build spells it differently, say so here rather than in a reconnect loop.
  const names = parameterNamesOf(opener)
  if (names === undefined || !names.includes('signal')) {
    console.warn(
      `[mac-gateway] approval relay: the stream opener declares ${names === undefined ? 'no readable parameters' : `no \`signal\` (${names.join(', ')})`}; feeding it positionally, cancellation last. reads: ${Function.prototype.toString.call(opener).slice(0, 160)}`,
    )
  }

  return {
    // `$events` speaks the relay's own vocabulary, so the stream is typed as
    // such at this one boundary — the opener itself is untyped upstream.
    openWireStream: (endpoint, payload, signal) =>
      openStreamThrough(opener, { endpoint, payload, signal }) as Promise<AsyncIterable<UpstreamWireFrame>>,
    // Same reason as the opener: the answer door is a private member too, and
    // its parameters may move (实施期修正 15).
    dispatchRpc: (endpoint, payload, signal) => callThrough(dispatchRpc, { endpoint, payload, signal }),
  }
}

/**
 * The broadcast face for the relay. The WS adapter owns the socket set; the
 * broadcaster handed to the relay is wired up when the listener effect runs,
 * so it forwards through a stable indirection that exists before the server.
 */
function broadcasterOver(): { broadcast(frame: unknown): void } {
  let sink: ((frame: unknown) => void) | undefined
  approvalBroadcasterSink = (fn) => { sink = fn }
  return { broadcast: (frame) => sink?.(frame) }
}

/** Wiring point for {@link broadcasterOver}; assigned once when the listener starts. */
let approvalBroadcasterSink: ((sink: (frame: unknown) => void) => void) | undefined

/** The part of `ctx.sessionController` the prompt pump calls. */
function promptControllerOver(ctx: Context): PromptControllerLike {
  const controller = ctx.sessionController as unknown as {
    prompt(request: {
      requestId: string
      sessionId: string
      mode: 'queue' | 'steer'
      content: readonly { type: 'text'; text: string }[]
    }, signal: AbortSignal): Promise<{ accepted: true }>
  }
  return { prompt: (request, signal) => controller.prompt(request, signal) }
}

/**
 * Answer `pair` / `refresh` — the two ops that establish and exercise the
 * relationship. Kept beside the gate rather than inside `handle` on purpose:
 * the protocol contract stays a pure read protocol, and these two are the only
 * messages whose authority comes from the body rather than the header.
 */
async function handleAuthOp(
  op: 'pair' | 'refresh',
  message: unknown,
  vault: CredentialVault,
): Promise<{ status: number; body: unknown }> {
  const payload = message as { code?: unknown; deviceToken?: unknown }

  if (op === 'pair') {
    const outcome = vault.pair(payload.code)
    if (!outcome.ok) {
      return { status: 401, body: refusal('invalid-pairing-code', outcome.reason) }
    }
    return {
      status: 200,
      body: { v: PROTOCOL_VERSION, ok: true, deviceToken: outcome.deviceToken },
    }
  }

  const outcome = vault.refresh(payload.deviceToken)
  if (!outcome.ok) {
    return {
      status: 401,
      body: refusal('unauthenticated', 'unknown device token — pair again'),
    }
  }
  return {
    status: 200,
    body: { v: PROTOCOL_VERSION, ok: true, accessToken: outcome.accessToken, expiresAt: outcome.expiresAt },
  }
}

/** Thrown when a request body exceeds {@link MAX_BODY_BYTES}. */
class TooLargeError extends Error {
  constructor() {
    super(`body exceeds ${MAX_BODY_BYTES} bytes`)
    this.name = 'TooLargeError'
  }
}

/**
 * Read a request body, refusing to grow past the ceiling.
 *
 * The limit is enforced while collecting rather than after, so an oversized
 * body is never fully buffered — the point of the ceiling.
 */
async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const buffer = chunk as Buffer
    size += buffer.length
    if (size > MAX_BODY_BYTES) throw new TooLargeError()
    chunks.push(buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}
