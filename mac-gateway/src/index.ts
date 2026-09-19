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
 * serve. See docs/protocol.md §4.1 for why the list can be served this way.
 *
 * Runtime imports are deliberately limited to Node builtins plus our own
 * modules. This module lives outside the dsh installation, so a bare specifier
 * such as `@deepseek-ai/cordis` does NOT resolve from here (verified:
 * MODULE_NOT_FOUND — no `node_modules` exists in any parent directory). The
 * cordis import below is type-only and therefore erased by Node's type stripping.
 *
 * See docs/plans/M0-reachability-spike.md §4.3 Steps 2–3 and docs/protocol.md.
 */
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import { DEFAULT_LIMITS, handle, type Limits, type SessionPort } from './seam/rpc.ts'
import { createSessionPort, type ListSource, type PersistenceLike } from './adapters/sessions.ts'
import { attachStreamHandler, type FollowSource, type UpstreamFollowFrame } from './adapters/ws.ts'

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
]

/** Plugin config, supplied by the owning patch row. */
export interface Config {
  /** Bind address. `0.0.0.0` reaches the LAN; `127.0.0.1` is loopback only. @default '0.0.0.0' */
  host?: string
  /** Bind port. @default 3081 */
  port?: number
  /**
   * Most events one `snapshot` reply may carry. Config rather than a constant so
   * the caps are observable end to end (see docs/protocol.md §五). @default 500
   */
  maxDeltaEvents?: number
  /** Soft ceiling on one reply's serialized `events`, in bytes. @default 1048576 */
  maxDeltaBytes?: number
}

/** All-interfaces bind: the whole point of M0 (see docs/spec.md §四 M0). */
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

  console.log('[mac-gateway] plugin loaded')

  ctx.effect(() => {
    const server = createServer((request, response) => {
      // `respond` never rejects; a throw here would be an unhandled rejection.
      void respond(request, response, sessionPort, limits)
    })

    // The stream channel shares the listener: same port, `POST /rpc` for the
    // one-way calls, `/rpc/stream` upgrade for the follow stream.
    attachStreamHandler(server, streamSourceOver(ctx))

    // console.* rather than ctx.logger: in our non-TTY verification runs
    // `ctx.logger.info` produced no stdout line at all (dsh's own startup line
    // was missing too), and a bind failure that cannot be seen is worse than a
    // non-idiomatic one. Whether the logger is merely TTY-gated is unverified —
    // see docs/plans/M0-reachability-spike.md §5.1.
    server.on('error', (error) => {
      console.error(`[mac-gateway] listener error: ${String(error)}`)
    })

    server.listen(port, host, () => {
      console.log(`[mac-gateway] listening on http://${host}:${port}`)
    })

    return () => {
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
 * Each method mirrors one thing the reference list does (docs/plans/M1-consistency-delta.md
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
      const snapshot = cache.cachedSnapshot(header, 0) ?? cache.cachedPredecessorTitle(header, 0)
      return snapshot?.values
    },

    isRunning(sessionId) {
      return (ctx.agents as unknown as AgentsLike).get(sessionId)?.status === 'running'
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
function streamSourceOver(ctx: Context): FollowSource {
  const controller = ctx.sessionController as unknown as {
    follow(request: {
      address: { kind: 'session'; sessionId: string }
      maxMessages?: number
      assistantStream: true
    }, signal: AbortSignal): AsyncIterable<UpstreamFollowFrame>
  }
  return { follow: (request, signal) => controller.follow(request, signal) }
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
  cachedSnapshot(session: unknown): { values: Readonly<Record<string, unknown>> } | undefined
}

/** The part of `ctx.sessionProjectionCache` this module uses. */
interface ProjectionCacheLike {
  cachedSnapshot(header: never, inheritedEventCount: number): { values: Readonly<Record<string, unknown>> } | undefined
  cachedPredecessorTitle(header: never, inheritedEventCount: number): { values: Readonly<Record<string, unknown>> } | undefined
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
): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://gateway').pathname

  if (path !== '/rpc') {
    // Liveness, and the answer to any unknown path. Transport-level only: no
    // protocol message is involved, so no envelope is involved either.
    response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(path === '/' ? 'mac-gateway alive — M1, protocol v2, POST /rpc for the protocol\n' : 'not found\n')
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

  const answer = await handle(message, port, Date.now, limits)
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${JSON.stringify(answer)}\n`)
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
