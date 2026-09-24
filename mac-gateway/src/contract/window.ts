/**
 * The backwards-window arithmetic, shared by `page` (rpc.ts), the follow opening
 * (mux.ts), and the follow request's window spelling (adapters → remote/ws.ts).
 *
 * `maxMessages` is a **target**, not a promise: the caller gets a window that
 * **starts on a turn boundary** — one opening mid-turn has no fold header so it
 * lies flat, and paging back to that turn's opening folds the same run up instead
 * (same content, two shapes; spec §8.5 B6 二次裁决). Twice the target stops the
 * walk, so an unreachable boundary cannot widen the window without limit. Real
 * logs never reach it — aligning cost 5–18 events across four sessions.
 */

/** How much wider than its target a window may get while walking back to a `turn/start`. */
const TURN_ALIGN_CEILING = 2

/**
 * The event types that count as a message when a page boundary is drawn. A
 * boundary-drawing rule, not a display rule: a client draws fewer (an injected
 * `user/message` has `source.kind !== "user"`), and a window may be wider than
 * what gets drawn, never narrower.
 */
const MESSAGE_EVENT_TYPES: ReadonlySet<string> = new Set(['user/message', 'assistant/message'])

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
import type { WireEvent } from './rpc.ts'

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
