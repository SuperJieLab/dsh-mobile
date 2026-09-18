/**
 * The protocol seam: one wire message in, one wire message out.
 *
 * `handle` is deliberately a plain async function with its data source injected.
 * It knows nothing about HTTP, sockets, the DSH runtime, or the session store —
 * so the same function is exercised by the seam tests, by `curl` over real HTTP,
 * and by the iPhone client, and it is what a future transport (WebSocket, raw
 * TCP) would call unchanged. That is the executable form of the first constraint
 * in docs/protocol.md: the protocol is defined as messages, not as URLs.
 *
 * Water-mark semantics (docs/protocol.md §五): both bounds are half-open.
 *   - `since` is the client's *next expected seq* — the server returns `seq >= since`.
 *     `0` therefore means "I have nothing", which is why the client can send it
 *     unconditionally.
 *   - `asOfSeq` is the position this reply covers up to, exclusive. A client that
 *     stores it and sends it back as `since` never misses and never re-fetches.
 *
 * See docs/plans/M1-lan-mvp.md §4.3 Step 3.
 */

/** The only protocol version this build speaks. */
export const PROTOCOL_VERSION = 1

/**
 * One session event as it travels on the wire: the DSH event object passed
 * through verbatim, unknown fields included. The protocol promises the fields
 * below; it does not promise their absence-of-extras, so clients must tolerate
 * fields they do not know.
 */
export interface WireEvent {
  /** DSH event type, e.g. `user/message`. */
  type: string
  /** Monotonic sequence number within the session, contiguous from 0. */
  seq: number
  /** Unix epoch milliseconds. */
  time: number
  /** Opaque payload; the protocol layer never interprets it. */
  data: unknown
  [extraField: string]: unknown
}

/** One row of the session list — the fields the list path promises. */
export interface SessionSummary {
  /** Stored session id. */
  id: string
  /** Log-derived title; absent when the session has no `session/title` event. */
  title?: string
  /** Unix epoch milliseconds the session was created. */
  createdAt: number
  /** Unix epoch milliseconds of the newest event (creation time when the log is empty). */
  updatedAt: number
  /** Number of events in the stored log. */
  eventCount: number
}

/** The slice of one session log a read produced, plus the water mark it reached. */
export interface SessionSlice {
  /** Next expected seq — see the half-open rule above. */
  asOfSeq: number
  /** Events with `seq >= since`, in seq order. */
  events: readonly WireEvent[]
}

/**
 * The data source the protocol layer is written against — the seam's only
 * dependency. Swapping the DSH-backed adapter for a fake is how the tests stay
 * free of any runtime, filesystem, or network.
 */
export interface SessionPort {
  /** Every stored session visible to this process. Order carries no meaning. */
  list(): Promise<readonly SessionSummary[]>
  /** Events with `seq >= since`, or `undefined` when no such session exists. */
  read(id: string, since: number): Promise<SessionSlice | undefined>
}

/** A refusal. `code` is one of the codes in docs/protocol.md §六. */
export interface WireError {
  code: string
  message: string
}

/** Any successful response. Extra fields are per-op. */
export interface OkResponse {
  v: typeof PROTOCOL_VERSION
  ok: true
  [field: string]: unknown
}

/** Any refused response. */
export interface ErrorResponse {
  v: typeof PROTOCOL_VERSION
  ok: false
  error: WireError
}

/** One response, successful or refused. */
export type Response = OkResponse | ErrorResponse

/**
 * Answer one message.
 *
 * @param message - the parsed JSON body, of unknown shape by construction.
 * @param port - the data source; every read goes through it.
 * @param now - clock for `serverTime`, injectable so tests are deterministic.
 * @returns the response envelope. This function does not throw: a hostile or
 *   wedged data source becomes a refusal, because "the process must not crash"
 *   is one of the criteria this step is judged by.
 */
export async function handle(
  message: unknown,
  port: SessionPort,
  now: () => number = Date.now,
): Promise<Response> {
  const envelope = asRecord(message)
  if (envelope === undefined || envelope.v !== PROTOCOL_VERSION) {
    return failure('unsupported-version', `expected an object with v: ${PROTOCOL_VERSION}`)
  }

  const op = envelope.op
  if (typeof op !== 'string') return failure('unknown-op', 'request has no op')

  try {
    switch (op) {
      case 'list-sessions':
        return await listSessions(port, now)
      case 'snapshot':
        return await snapshot(envelope, port)
      default:
        return failure('unknown-op', `unsupported op "${op}"`)
    }
  } catch (error) {
    // Two distinct refusals, because they need different client behaviour: a
    // log this runtime refuses to interpret is a stored session that cannot be
    // shown, while anything else is our own failure.
    return isUnreadable(error)
      ? failure('unreadable-session', describe(error))
      : failure('internal-error', describe(error))
  }
}

/** The list path: cheap per-session metadata, newest first. */
async function listSessions(port: SessionPort, now: () => number): Promise<Response> {
  const summaries = [...await port.list()]
  // Newest first is a promise the client can rely on instead of guessing, and
  // it is decided here rather than in the client so every client agrees.
  summaries.sort((left, right) => right.updatedAt - left.updatedAt)
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    serverTime: now(),
    sessions: summaries.map(toWireSummary),
  }
}

/** One summary as the wire shape, omitting `title` rather than sending null. */
function toWireSummary(summary: SessionSummary): Record<string, unknown> {
  return {
    id: summary.id,
    ...summary.title === undefined ? {} : { title: summary.title },
    createdAt: summary.createdAt,
    updatedAt: summary.updatedAt,
    eventCount: summary.eventCount,
  }
}

/** The read path: one session's events from the client's water mark onward. */
async function snapshot(envelope: Record<string, unknown>, port: SessionPort): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    // `unknown-session` rather than a new code: an id that is not a non-empty
    // string can never name a stored session, so the caller's remedy is the same.
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }

  const since = normalizeSince(envelope.since)
  const slice = await port.read(sessionId, since)
  if (slice === undefined) return failure('unknown-session', `no stored session "${sessionId}"`)

  return {
    v: PROTOCOL_VERSION,
    ok: true,
    sessionId,
    asOfSeq: slice.asOfSeq,
    events: [...slice.events],
  }
}

/**
 * A missing or nonsense `since` reads as `0` — "send me everything" — instead of
 * a new error code. The client de-duplicates by `seq`, so the cost of the
 * lenient reading is a redundant payload, never a wrong view.
 */
function normalizeSince(value: unknown): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : 0
}

/** Whether an error means "stored, but this runtime will not interpret it". */
function isUnreadable(error: unknown): boolean {
  const name = (error as { name?: unknown } | null)?.name
  return name === 'SessionFormatUnsupportedError' || name === 'SessionPersistenceCorruptionError'
}

/** A human-readable reason, for the refusal message only. */
function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** A plain object, as opposed to an array, null, or a primitive. */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined
}

/** Build a refusal. Every refusal carries `v`, exactly like a success does. */
function failure(code: string, message: string): ErrorResponse {
  return { v: PROTOCOL_VERSION, ok: false, error: { code, message } }
}
