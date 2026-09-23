/**
 * The protocol contract: one wire message in, one wire message out.
 *
 * `handle` is a plain async function with its data source injected: no HTTP,
 * sockets, DSH runtime, or session store. Every transport runs it unchanged —
 * the protocol is messages, not URLs (docs/dev/protocol.md;
 * docs/dev/plans/M0-reachability-spike.md §4.3 Step 3). Water marks (§五): both
 * bounds half-open. `since` is the client's *next expected seq* (`0` = "I have
 * nothing"); `asOfSeq` is covered up to, exclusive, and sent back as `since`
 * never misses or re-fetches. Two non-overlapping reads: `snapshot` forward from
 * a cursor, `page` backward to a window to open on (§4.2 / §4.3).
 *
 * Reply caps: one reply ≤ `maxDeltaEvents` events and, softly, `maxDeltaBytes`;
 * an early stop says so with `hasMore`. Caps bound one reply, never what a
 * sequence adds up to (docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 4).
 */

import { describeError, isUnreadable } from './errors.ts'
import {
  approvalAnswerOf,
  sessionPromptOf,
  type WritePort,
} from './write.ts'

/** The only protocol version this build speaks. */
export const PROTOCOL_VERSION = 2

/**
 * One session event on the wire: the DSH event object verbatim, unknown fields
 * included. The protocol promises the fields below, not their exclusivity, so
 * clients must tolerate unknown fields.
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
 * One row of the session list — the fields the list path promises (v2). Every
 * field comes from a session header or an already-kept projection, so listing
 * is zero-I/O: nothing here needs a log read (docs/dev/protocol.md §4.1).
 */
export interface SessionRow {
  /** Stored session id. */
  id: string
  /**
   * Current title. Absent when the session has none *and* when no projection
   * was available — a missing title is the contract, not a fault.
   */
  title?: string
  /** Unix epoch milliseconds the session was created. */
  createdAt: number
  /**
   * Unix epoch milliseconds of the last user prompt; creation time when there is
   * none. **Not** the newest event's time (v1 promised that, forcing a log read).
   */
  updatedAt: number
  /** Whether an agent is currently running for this session. */
  running: boolean
  /** Whether the session has no turn yet. Showing it is the client's call. */
  blank: boolean
  /**
   * `'subagent'` when this session is another session's child; absent otherwise.
   * Carried so the client can apply the reference UI's visibility rule itself —
   * the server states the fact, the drawing stays the client's call.
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
   * while `since` is positive. The only wrong cursor the data source can prove —
   * a `since` past the water mark reads as "caught up"
   * (docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 5).
   */
  staleCursor: boolean
}

/**
 * The data source the protocol layer is written against — the contract's only
 * dependency; a fake keeps the tests free of runtime, filesystem, and network.
 */
export interface SessionPort {
  /** Every session visible to this process. Order carries no meaning. */
  list(): Promise<readonly SessionRow[]>
  /**
   * At most `limit` events with `seq >= since`, or `undefined` when no such
   * session exists. The slice reports whether more remain.
   */
  read(id: string, since: number, limit: number): Promise<SessionSlice | undefined>
  /**
   * The entire log, or `undefined` when no such session exists. Backwards
   * windows need the log's end, and the storage read API only walks forward from
   * an offset — the whole log is the price of reaching the tail. The list path
   * no longer pays it (v2 reads projections); `page` still does.
   */
  readAll(id: string): Promise<readonly WireEvent[] | undefined>
}

/**
 * How large one `snapshot` reply may get; one reply only, never a client's view.
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
 * Messages one `page` returns when the caller does not say; mirrors the
 * reference client's page size. A *window*, not a cap: no `hasMore` loop here.
 */
export const DEFAULT_PAGE_MESSAGES = 50

/**
 * How much wider than its target a window may get while walking back to a
 * `turn/start`. `maxMessages` is a target, not a promise: the caller gets a
 * window that **starts on a turn boundary** — one opening mid-turn has no fold
 * header so it lies flat, and paging back to that turn's opening folds the same
 * run up instead (same content, two shapes; spec §8.5 B6 二次裁决).
 *
 * Twice the target stops the walk, so an unreachable boundary cannot widen
 * the window without limit. Real logs never reach it — aligning cost 5–18
 * events across four sessions.
 */
const TURN_ALIGN_CEILING = 2

/**
 * The event types that count as a message when a page boundary is drawn. A
 * boundary-drawing rule, not a display rule: a client draws fewer (an injected
 * `user/message` has `source.kind !== "user"`), and a window may be wider than
 * what gets drawn, never narrower.
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
 * @returns the response envelope. Never throws: a hostile or wedged data source
 *   becomes a refusal ("the process must not crash" is a judged criterion).
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
    // Two refusals, needing different client behaviour: a log this runtime will
    // not interpret is a session that cannot be shown, anything else is ours.
    return isUnreadable(error)
      ? failure('unreadable-session', describeError(error))
      : failure('internal-error', describeError(error))
  }
}

/**
 * Deliver one approval answer (M5). `ok` means *delivered to the pending
 * question* — the authoritative outcome is the `approval/decided` audit event
 * the client reconciles from the stream (Plan §3.3 决定 3).
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

/**
 * Admit one prompt (M5). `ok` means *accepted into the inbox* — the reply itself arrives
 * via the stream.
 */
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
  // Sorted here rather than in the client, so every client agrees on the order.
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
 * `eventCount` is deliberately absent: a log-derived fact would put the log
 * back on the list path (docs/dev/protocol.md §4.1).
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
    // An error code, not a silent empty reply: the whole view is untrustworthy,
    // and a boolean would be swallowed (docs/dev/protocol.md §六).
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
 * just before `beforeSeq` — see {@link pageWindow} for the boundary rules.
 */
async function page(envelope: Record<string, unknown>, port: SessionPort): Promise<Response> {
  const sessionId = envelope.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') {
    return failure('unknown-session', 'sessionId must be a non-empty string')
  }

  const maxMessages = isPositiveInteger(envelope.maxMessages)
    ? envelope.maxMessages
    : DEFAULT_PAGE_MESSAGES

  // A malformed `beforeSeq` degrades to the newest window, as a malformed
  // `since` degrades to `0`: a legal answer, at worst one window too many.
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
    // Two refusals, same codes as before the extraction: an uninterpretable log
    // is `unreadable-session`, a cursor past the end is `resync-required`
    // (docs/dev/plans/M1-consistency-delta.md 判据 P4).
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
 * One backwards window over a whole log — the arithmetic `page` and the follow
 * opening share, so they cannot drift apart. Bounded by *messages* but delivered
 * as the whole interval, since a drawn seq's neighbours are frequently not
 * messages (docs/dev/protocol.md §4.3). Its **start** moves back to the nearest
 * `turn/start` so it never opens mid-turn — {@link TURN_ALIGN_CEILING} covers
 * why and how far.
 *
 * @throws {@link LogNotDenseError} when seqs are not `0..n-1`: the arithmetic
 *   reads positions as seqs, so density is a precondition. Both callers refuse
 *   with `unreadable-session`.
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
    // Unlike `snapshot` this bound is knowable — the whole log is in hand — so a
    // position past the end is refused, not answered with an empty window.
    throw new CursorPastEndError(sessionId, end, events.length)
  }

  let start = 0
  let counted = 0
  for (let index = end - 1; index >= 0; index -= 1) {
    const event = events[index]
    // A turn boundary wins over the count: once the target is met, walk on to the
    // *nearest* `turn/start`. `turn/start` is not a message, so the count holds.
    if (event?.type === 'turn/start' && counted >= maxMessages) {
      start = index
      break
    }
    if (event === undefined || !MESSAGE_EVENT_TYPES.has(event.type)) continue
    counted += 1
    if (counted >= maxMessages * TURN_ALIGN_CEILING) {
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
 * The reference host's spelling of the same window rule, from the one target
 * {@link pageWindow} takes.
 *
 * The reference splits the rule into a floor it may stop after and a ceiling it
 * must stop at; ours derives the ceiling from the target
 * ({@link TURN_ALIGN_CEILING}). Both cap the walk at twice the target, so the
 * follow opening and `page` stay aligned.
 */
export function upstreamWindow(targetMessages: number): {
  maxMessages: number
  turnWindow: { minMessages: number; minTurns: number }
} {
  return {
    maxMessages: targetMessages * TURN_ALIGN_CEILING,
    // The reference counts a turn the moment it meets one, so `minTurns: 1`
    // means "the nearest boundary wins" — what our walk does too.
    turnWindow: { minMessages: targetMessages, minTurns: 1 },
  }
}

/**
 * Keep the longest prefix of `events` that fits under the byte cap. The cap is
 * soft: dropping every event would leave the client unable to advance, so the
 * first event goes even if it alone exceeds the cap — which is exactly what
 * bounds the pathological reply.
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
 * One event's serialized size. `TextEncoder`, not `Buffer`: no host-specific
 * APIs, so it runs wherever the messages travel.
 */
function wireBytesOf(event: WireEvent): number {
  return ENCODER.encode(JSON.stringify(event)).length
}

const ENCODER = new TextEncoder()

/**
 * A nonsense cap must not become a stall: a non-positive or non-integer one
 * falls back to the default, never to a reply no client can finish reading.
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
 * A missing or nonsense `since` reads as `0` — "send me everything" — rather
 * than a new error code: the client de-duplicates by `seq`, so leniency costs a
 * redundant payload, never a wrong view.
 */
function normalizeSince(value: unknown): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : 0
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
