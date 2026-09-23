/**
 * The usage contract (M6): context occupancy, from two projection values to one
 * frame payload — pure functions, like every other file in this directory.
 *
 * Occupancy is the first thing in this project that the client **cannot** work
 * out for itself: the numerator folds every surface node including compaction
 * shadows, and the denominator is published only when a route advertises one,
 * so it can sit outside whatever window the phone happens to hold. The upstream
 * reference UI reads exactly these two values and does exactly this arithmetic
 * (`ui-conversation/src/client/context-occupancy.ts:15-25`): numerator is
 * `projectedTokens ?? pressureTokens`, denominator is `contextWindow`, and the
 * display side caps and rounds. Nothing here re-derives a number the host
 * already knows (docs/dev/plans/M6-presentation-layer.md §2.1).
 *
 * The two halves come from **two independently registered projection keys**
 * (`@deepseek-ai/dsh-token-meter` registers `contextPressure` and
 * `contextBreakdown` as separate units, each updated on its own terms), so this
 * module takes one cut of both and turns them into a single payload. Two rules
 * are the contract's own:
 *
 *   - **Nothing displayable means no payload.** A missing numerator or
 *     denominator is "unknown", never 0% — the client hides the row instead of
 *     printing a number nobody can trust (§3.1 决定 4, 判据 U2).
 *   - **One water mark for both keys.** The payload travels with the cut's
 *     `asOfSeq`, so no client can ever assemble a fresh ratio with a stale
 *     breakdown (§3.1 决定 6, 判据 U7).
 *
 * The `asOfSeq` this module stamps is whatever the caller read the values at.
 * Which read it must be — and why the conservative cached one is the wrong
 * choice here — is argued in §3.1 决定 3.
 *
 * See docs/dev/protocol.md §4.4 for the wire shape and
 * docs/dev/plans/M6-presentation-layer.md §3.1 for the reasoning.
 */

/**
 * The pressure half of the projection, as its wire view publishes it. Every
 * field is optional: the unit drops a field when it has never observed one
 * (`dsh-token-meter`'s `pressureSchema`).
 */
export interface PressureValues {
  /** Provider-reported prompt size of the most recent request. */
  pressureTokens?: number
  /**
   * What the next request's prompt would cost — `pressureTokens` plus the
   * heuristic repricing of surface movement since the sample was taken.
   */
  projectedTokens?: number
  /** Newest recorded route capacity; absent when no adapter advertised one. */
  contextWindow?: number
}

/**
 * The composition half: heuristic system / tools / message split of the next
 * request. Deliberately **not** a decomposition of `usedTokens` — the
 * estimator underprices CJK text and JSON schemas, so these three never sum to
 * the anchored numerator (§3.1 决定 6).
 */
export interface BreakdownValues {
  systemTokens: number
  toolsTokens: number
  messageTokens: number
}

/** What the phone draws: one ratio, and how much of the context it describes. */
export interface UsagePayload {
  /** The numerator: provider-anchored, never estimated here. */
  usedTokens: number
  /** The denominator. */
  contextWindow: number
  /**
   * Present only when all three parts are known and not all zero. Absence
   * never suppresses the ratio — it only omits the expanded rows (§3.1 决定 6).
   */
  breakdown?: BreakdownValues
}

/**
 * One water mark plus whatever is displayable at it. Absent `usage` is a
 * statement, not a gap: at this cut there is nothing to show, so a client that
 * is showing something older clears it.
 */
export interface UsageSnapshot {
  /** The cut these values were read at — the log's water mark, not a window bound. */
  asOfSeq: number
  usage?: UsagePayload
}

/**
 * Turn one cut of the projection values into the snapshot to send.
 *
 * The rules, in order: a numerator is required (`projectedTokens` first, then
 * `pressureTokens` — the same preference the reference UI states) and so is a
 * positive `contextWindow`; both must be integers, because the projection's own
 * schema says so and a bad value must not reach a percentage (§3.1 决定 4, 判据 U4).
 *
 * @param values - the projection values as read, opaque keyed by projection key.
 * @param asOfSeq - the water mark the values were read at.
 * @returns the snapshot; `usage` is absent when nothing is displayable.
 */
export function usageSnapshotOf(values: Readonly<Record<string, unknown>>, asOfSeq: number): UsageSnapshot {
  const pressure = asRecord(values['contextPressure'])
  const projected = nonNegativeInteger(pressure?.['projectedTokens'])
  const sampled = nonNegativeInteger(pressure?.['pressureTokens'])
  const usedTokens = projected ?? sampled
  const contextWindow = positiveInteger(pressure?.['contextWindow'])
  if (usedTokens === undefined || contextWindow === undefined) return { asOfSeq }
  const breakdown = breakdownOf(asRecord(values['contextBreakdown']))
  return {
    asOfSeq,
    usage: {
      usedTokens,
      contextWindow,
      ...(breakdown === undefined ? {} : { breakdown }),
    },
  }
}

/**
 * Whether an event is a reason to re-read the projections.
 *
 * Three event types carry them, verified at the runtime
 * (`dsh-token-meter`'s `usage-projection.ts`): `assistant/message` and
 * `assistant/attempt` both contribute a usage sample (`usageOf`, `:82-86`,
 * applied at `:128`), and `request/context` is the only source of
 * `contextWindow` (`:181-191`).
 *
 * ⚠️ The upstream unit distinguishes two shapes of usage — handed over in
 * `data.usage`, or buried in the last chunk of `data.stream` — and this
 * function deliberately does not: re-reading is an in-memory synchronous read
 * and a re-read that changes nothing sends nothing (§3.1 决定 3, 判据 U5).
 * Telling the shapes apart here would only add a way to miss a sample.
 *
 * @param event - the event, judged by type alone.
 */
export function usageIsTrigger(event: { type: string }): boolean {
  return event.type === 'assistant/message'
    || event.type === 'assistant/attempt'
    || event.type === 'request/context'
}

/**
 * Whether a fresh snapshot is worth a frame.
 *
 * The point is not to be clever: values that changed must travel, values that
 * did not must not (a busy turn settles several times), and a payload that
 * became absent is a change like any other — it is what tells the client to
 * stop showing the old number (§3.1 决定 3, 判据 U3).
 *
 * @param previous - the last snapshot sent on this stream, if any.
 * @param next - the snapshot just read.
 */
export function usageShouldEmit(previous: UsageSnapshot | undefined, next: UsageSnapshot): boolean {
  return !sameUsage(previous?.usage, next.usage)
}

/** Non-negative integer, or `undefined` — the projection's own numeric contract. */
function nonNegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined
}

/** Positive integer, or `undefined` — a zero capacity cannot be divided by. */
function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : undefined
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  return value as Record<string, unknown>
}

/**
 * The three parts, or nothing.
 *
 * All three are required together (a partial split would mislead more than it
 * informs), and three zeros are as good as absent — an untouched session has
 * no composition worth expanding (§3.1 决定 6, 判据 U8).
 */
function breakdownOf(values: Record<string, unknown> | undefined): BreakdownValues | undefined {
  if (values === undefined) return undefined
  const systemTokens = nonNegativeInteger(values['systemTokens'])
  const toolsTokens = nonNegativeInteger(values['toolsTokens'])
  const messageTokens = nonNegativeInteger(values['messageTokens'])
  if (systemTokens === undefined || toolsTokens === undefined || messageTokens === undefined) return undefined
  if (systemTokens === 0 && toolsTokens === 0 && messageTokens === 0) return undefined
  return { systemTokens, toolsTokens, messageTokens }
}

function sameUsage(a: UsagePayload | undefined, b: UsagePayload | undefined): boolean {
  if (a === undefined || b === undefined) return a === b
  return a.usedTokens === b.usedTokens
    && a.contextWindow === b.contextWindow
    && sameBreakdown(a.breakdown, b.breakdown)
}

function sameBreakdown(a: BreakdownValues | undefined, b: BreakdownValues | undefined): boolean {
  if (a === undefined || b === undefined) return a === b
  return a.systemTokens === b.systemTokens
    && a.toolsTokens === b.toolsTokens
    && a.messageTokens === b.messageTokens
}
