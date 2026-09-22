/**
 * The protocol seam: one wire message in, one wire message out.
 *
 * `handle` is deliberately a plain async function with its data source injected.
 * It knows nothing about HTTP, sockets, the DSH runtime, or the session store —
 * so the same function is exercised by the seam tests, by `curl` over real HTTP,
 * and by the iPhone client, and it is what a future transport (WebSocket, raw
 * TCP) would call unchanged. That is the executable form of the first constraint
 * in docs/dev/protocol.md: the protocol is defined as messages, not as URLs.
 *
 * Water-mark semantics (docs/dev/protocol.md §五): both bounds are half-open.
 *   - `since` is the client's *next expected seq* — the server returns `seq >= since`.
 *     `0` therefore means "I have nothing", which is why the client can send it
 *     unconditionally.
 *   - `asOfSeq` is the position this reply covers up to, exclusive. A client that
 *     stores it and sends it back as `since` never misses and never re-fetches.
 *
 * Two read directions live here and they do not overlap: `snapshot` walks
 * forward from a cursor, `page` walks backwards from a position to build a
 * window to open on (docs/dev/protocol.md §4.2 / §4.3).
 *
 * Reply caps (docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 4): one reply carries
 * at most `maxDeltaEvents` events and, softly, `maxDeltaBytes` of serialized
 * `events`; a reply that stops early says so with `hasMore` so the client can
 * loop. The caps bound one reply's size — they never change what the sequence of
 * replies adds up to, which is what the chunking test pins down.
 *
 * See docs/dev/plans/M0-reachability-spike.md §4.3 Step 3 and docs/dev/protocol.md.
 */

import {
  approvalAnswerOf,
  sessionPromptOf,
  type WritePort,
} from './write.ts'

/** The only protocol version this build speaks. */
export const PROTOCOL_VERSION = 2

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

/**
 * One row of the session list — the fields the list path promises (v2).
 *
 * Every field here comes from a session header or from a projection the host
 * already keeps. That is what makes listing zero-I/O: **nothing in this shape
 * requires reading a log** (docs/dev/protocol.md §4.1).
 */
export interface SessionRow {
  /** Stored session id. */
  id: string
  /**
   * Current title. Absent when the session has none *and* when no projection was
   * available — a missing title is part of the contract, not a fault.
   */
  title?: string
  /** Unix epoch milliseconds the session was created. */
  createdAt: number
  /**
   * Unix epoch milliseconds of the last user prompt; creation time when there is
   * none. **Not** the newest event's time — assistant output and tool calls do
   * not move it (v1 promised the latter, which forced a log read).
   */
  updatedAt: number
  /** Whether an agent is currently running for this session. */
  running: boolean
  /** Whether the session has no turn yet. Showing it is the client's call. */
  blank: boolean
  /**
   * `'subagent'` when this session is another session's child; absent otherwise.
   *
   * Carried so a client can apply the reference UI's visibility rule itself. The
   * server states the fact; what to draw stays the client's decision.
   */
  origin?: string
}

/** The slice of one session log a read produced, plus the water mark it reached. */
export interface SessionSlice {
  /** Next expected seq — see the half-open rule above. */
  asOfSeq: number
  /** Events with `seq >= since`, in seq order, at most the requested limit. */
  events: readonly WireEvent[]
  /** Whether the log holds more events after this slice. */
  hasMore: boolean
  /**
   * The client's cursor names a position that cannot exist: the log is empty
   * while `since` is positive. This is the only wrong cursor the data source can
   * prove — a `since` merely past the water mark looks exactly like "caught up"
   * from here (docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 5).
   */
  staleCursor: boolean
}

/**
 * The data source the protocol layer is written against — the seam's only
 * dependency. Swapping the DSH-backed adapter for a fake is how the tests stay
 * free of any runtime, filesystem, or network.
 */
export interface SessionPort {
  /** Every session visible to this process. Order carries no meaning. */
  list(): Promise<readonly SessionRow[]>
  /**
   * At most `limit` events with `seq >= since`, or `undefined` when no such
   * session exists. The slice reports whether more remain, so the caller never
   * has to guess where the log ends.
   */
  read(id: string, since: number, limit: number): Promise<SessionSlice | undefined>
  /**
   * The entire log, or `undefined` when no such session exists.
   *
   * Backwards windows need the end of the log, and the storage read API only
   * walks forward from an offset — so the whole log is the price of reaching
   * the tail. The list path no longer pays this (v2 reads projections instead);
   * `page` still does.
   */
  readAll(id: string): Promise<readonly WireEvent[] | undefined>
}

/**
 * How large one `snapshot` reply may get. Constants by nature: they bound a
 * single reply and leave the sequence of replies — the part that carries meaning
 * — untouched, which is why tuning them cannot change a client's final view.
 */
export interface Limits {
  /** Most events one reply may carry. Must be positive. */
  maxDeltaEvents: number
  /** Soft ceiling on the serialized size of one reply's `events`. */
  maxDeltaBytes: number
}

/** Caps for a LAN demo: generous enough to rarely bind, small enough to bound. */
export const DEFAULT_LIMITS: Limits = { maxDeltaEvents: 500, maxDeltaBytes: 1_048_576 }

/**
 * Messages one `page` returns when the caller does not say.
 *
 * Mirrors the reference client's page size. It is a *window* size, not a cap:
 * one page is delivered whole, so there is no `hasMore` loop on this path.
 */
export const DEFAULT_PAGE_MESSAGES = 50

/**
 * The event types that count as a message when a page boundary is drawn.
 *
 * This is a boundary-drawing rule, not a display rule. A client shows fewer
 * messages than this (a `user/message` injected by the runtime carries
 * `source.kind !== "user"` and does not belong in a conversation), and that is
 * fine: a window may be wider than what gets drawn, never narrower.
 */
const MESSAGE_EVENT_TYPES: ReadonlySet<string> = new Set(['user/message', 'assistant/message'])

/** A refusal. `code` is one of the codes in docs/dev/protocol.md §六. */
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
 * @param limits - reply caps; nonsense values fall back to {@link DEFAULT_LIMITS}
 *   rather than producing a reply the client could never advance past.
 * @returns the response envelope. This function does not throw: a hostile or
 *   wedged data source becomes a refusal, because "the process must not crash"
 *   is one of the criteria this step is judged by.
 */
export async function handle(
  message: unknown,
  port: SessionPort,
  now: () => number = Date.now,
  limits: Limits = DEFAULT_LIMITS,
  write?: WritePort,
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
        return await snapshot(envelope, port, normalizeLimits(limits))
      case 'page':
        return await page(envelope, port)
      case 'approval-answer':
      case 'session-prompt':
        // Write ops (M5). `write` is absent only in read-only test assemblies;
        // production always wires it, so this refusal is unreachable there.
        if (write === undefined) return failure('internal-error', `write channel not wired for "${op}"`)
        return op === 'approval-answer'
          ? await approvalAnswer(envelope, write)
          : await sessionPrompt(envelope, write)
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

/**
 * Deliver one approval answer (M5). `ok` here means *delivered to the pending
 * question* — the authoritative outcome is the `approval/decided` audit event,
 * which the client reconciles from the stream (Plan §3.3 决定 3).
 */
async function approvalAnswer(envelope: Record<string, unknown>, write: WritePort): Promise<Response> {
  const answer = approvalAnswerOf(envelope)
  if (answer === undefined) {
    return failure('invalid-request', 'approval-answer needs eventId, decision ("allow" | "deny"), and answerId')
  }
  const outcome = await write.answerApproval(answer)
  if (outcome === 'unknown-approval') {
    return failure('unknown-approval', `no pending approval answers to "${answer.eventId}" — already decided, cancelled, or never asked`)
  }
  return { v: PROTOCOL_VERSION, ok: true, eventId: answer.eventId }
}

/** Admit one prompt (M5). `ok` means *accepted into the inbox* — the reply itself arrives via the stream. */
async function sessionPrompt(envelope: Record<string, unknown>, write: WritePort): Promise<Response> {
  const prompt = sessionPromptOf(envelope)
  if (prompt === undefined) {
    return failure('invalid-request', 'session-prompt needs sessionId, promptId, and non-whitespace text')
  }
  const outcome = await write.promptSession(prompt)
  if (outcome === 'unknown-session') {
    return failure('unknown-session', `no stored session "${prompt.sessionId}"`)
  }
  return { v: PROTOCOL_VERSION, ok: true, sessionId: prompt.sessionId }
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

/**
 * One row as the wire shape, omitting `title` rather than sending null.
 *
 * `eventCount` is deliberately absent: it is a log-derived fact, and promising
 * one would put the log back on the list path (docs/dev/protocol.md §4.1).
 */
function toWireSummary(row: SessionRow): Record<string, unknown> {
  return {
    id: row.id,
    ...row.title === undefined ? {} : { title: row.title },
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    running: row.running,
    blank: row.blank,
    ...row.origin === undefined ? {} : { origin: row.origin },
  }
}

/** The read path: one session's events from the client's water mark onward. */
async function snapshot(envelope: Record<string, unknown>, port: SessionPort, limits: Limits): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    // `unknown-session` rather than a new code: an id that is not a non-empty
    // string can never name a stored session, so the caller's remedy is the same.
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }

  const since = normalizeSince(envelope.since)
  const slice = await port.read(sessionId, since, limits.maxDeltaEvents)
  if (slice === undefined) return failure('unknown-session', `no stored session "${sessionId}"`)

  if (slice.staleCursor) {
    // An error code rather than a silent empty reply: the client's whole view is
    // untrustworthy, and a boolean field would be swallowed by clients that
    // tolerate unknown fields (docs/dev/protocol.md §六).
    return failure('resync-required', `since ${since} cannot exist: this session's log is empty`)
  }

  const events = fitToByteCap(slice.events, limits.maxDeltaBytes)
  const last = events.at(-1)
  return {
    v: PROTOCOL_VERSION,
    ok: true,
    sessionId,
    asOfSeq: last === undefined ? since : last.seq + 1,
    hasMore: slice.hasMore || events.length < slice.events.length,
    events: [...events],
  }
}

/**
 * The backwards window: the newest `maxMessages` messages, or the run ending
 * just before `beforeSeq`.
 *
 * Bounded by *messages* but delivered as the whole interval — a caller drawing
 * seq N needs its neighbours too, and those neighbours are frequently not
 * messages themselves (docs/dev/protocol.md §4.3).
 */
async function page(envelope: Record<string, unknown>, port: SessionPort): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }

  const maxMessages = isPositiveInteger(envelope.maxMessages)
    ? envelope.maxMessages
    : DEFAULT_PAGE_MESSAGES

  // A malformed `beforeSeq` degrades to the newest window, the same way a
  // malformed `since` degrades to `0`: the caller gets a legal answer, and the
  // worst case is one window it did not need.
  const requested = envelope.beforeSeq
  const beforeSeq = Number.isSafeInteger(requested) && (requested as number) >= 0
    ? requested as number
    : undefined

  const events = await port.readAll(sessionId)
  if (events === undefined) return failure('unknown-session', `no stored session "${sessionId}"`)

  let window: PageWindow
  try {
    window = pageWindow(sessionId, events, beforeSeq, maxMessages)
  } catch (error) {
    // Two distinct refusals, same codes as before the extraction: a log this
    // runtime cannot interpret is `unreadable-session`, a cursor past the end
    // is `resync-required` (docs/dev/plans/M1-consistency-delta.md 判据 P4).
    if (error instanceof LogNotDenseError) return failure('unreadable-session', error.message)
    if (error instanceof CursorPastEndError) return failure('resync-required', error.message)
    throw error
  }

  return {
    v: PROTOCOL_VERSION,
    ok: true,
    sessionId,
    pageStart: window.pageStart,
    asOfSeq: window.asOfSeq,
    hasOlder: window.hasOlder,
    events: [...window.events],
  }
}

/** Thrown by {@link pageWindow} when the log's seqs are not dense from 0. */
export class LogNotDenseError extends Error {
  constructor(sessionId: string, index: number, seq: string) {
    super(`session "${sessionId}" log is not dense: index ${index} holds seq ${seq}`)
    this.name = 'LogNotDenseError'
  }
}

/** Thrown by {@link pageWindow} when `beforeSeq` names a position past the log's end. */
export class CursorPastEndError extends Error {
  constructor(sessionId: string, beforeSeq: number, length: number) {
    super(`beforeSeq ${beforeSeq} is past the end of session "${sessionId}" (${length} events)`)
    this.name = 'CursorPastEndError'
  }
}

/**
 * One backwards window over a whole log — the arithmetic both `page` and the
 * follow opening share.
 *
 * Bounded by *messages* but delivered as the whole interval — a caller drawing
 * seq N needs its neighbours too, and those neighbours are frequently not
 * messages themselves (docs/dev/protocol.md §4.3). Sharing this one function is
 * what makes "the follow opening is the same window a `page` returns" a
 * structural fact rather than a promise: there is no second implementation to
 * drift from.
 *
 * @throws {@link LogNotDenseError} when the log's seqs are not `0..n-1` — the
 *   window arithmetic reads positions as seqs, so density is a precondition
 *   here rather than a hope. Both callers refuse on it: `page` with
 *   `unreadable-session`, the follow path likewise, rather than handing back a
 *   window whose boundary means something different than it says.
 */
export function pageWindow(
  sessionId: string,
  events: readonly WireEvent[],
  beforeSeq: number | undefined,
  maxMessages: number,
): PageWindow {
  const lastIndex = events.findIndex((event, index) => event.seq !== index)
  if (lastIndex !== -1) {
    throw new LogNotDenseError(sessionId, lastIndex, String(events[lastIndex]?.seq))
  }

  const end = beforeSeq ?? events.length
  if (end > events.length) {
    // Unlike `snapshot`, this bound is knowable: the whole log is in hand. So a
    // position past the end is refused rather than answered with an empty
    // window that looks exactly like "you have reached the beginning".
    throw new CursorPastEndError(sessionId, end, events.length)
  }

  let start = 0
  let counted = 0
  for (let index = end - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event === undefined || !MESSAGE_EVENT_TYPES.has(event.type)) continue
    counted += 1
    if (counted >= maxMessages) {
      start = index
      break
    }
  }

  return { pageStart: start, asOfSeq: end, hasOlder: start > 0, events: events.slice(start, end) }
}

/** One backwards window's geometry — see {@link pageWindow}. */
export interface PageWindow {
  /** First seq of the window (the client's next `beforeSeq` when paging back). */
  pageStart: number
  /** Exclusive upper bound the window reached. */
  asOfSeq: number
  /** Whether older events exist before the window. */
  hasOlder: boolean
  /** The window's events, in seq order. */
  events: readonly WireEvent[]
}

/**
 * Keep the longest prefix of `events` that fits under the byte cap.
 *
 * The cap is deliberately soft: dropping every event would leave the client with
 * an empty reply and no way to advance, so the first event is delivered even
 * when it alone exceeds the cap. This bounds the ordinary reply, not the
 * pathological one — the pathological one is bounded by being exactly one event.
 */
function fitToByteCap(events: readonly WireEvent[], maxBytes: number): readonly WireEvent[] {
  const kept: WireEvent[] = []
  let bytes = 0
  for (const event of events) {
    const size = wireBytesOf(event)
    if (kept.length > 0 && bytes + size > maxBytes) break
    kept.push(event)
    bytes += size
  }
  return kept
}

/**
 * One event's serialized size.
 *
 * `TextEncoder` rather than `Buffer`: this layer is the protocol, and it stays
 * free of host-specific APIs so the same function can run anywhere the messages
 * travel.
 */
function wireBytesOf(event: WireEvent): number {
  return ENCODER.encode(JSON.stringify(event)).length
}

const ENCODER = new TextEncoder()

/**
 * Caps are configuration, so a nonsense one must not become a stall: a
 * non-positive or non-integer cap falls back to the default rather than
 * producing replies the client can never finish reading.
 */
function normalizeLimits(limits: Limits): Limits {
  return {
    maxDeltaEvents: isPositiveInteger(limits.maxDeltaEvents)
      ? limits.maxDeltaEvents
      : DEFAULT_LIMITS.maxDeltaEvents,
    maxDeltaBytes: isPositiveInteger(limits.maxDeltaBytes)
      ? limits.maxDeltaBytes
      : DEFAULT_LIMITS.maxDeltaBytes,
  }
}

/** Whether `value` can serve as an upper bound for a loop. */
function isPositiveInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0
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
