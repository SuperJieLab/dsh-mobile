/**
 * The usage contract (M6): context occupancy, from two projection values to one
 * frame payload — pure functions, like every other file in this directory.
 *
 * Occupancy is the first thing the client **cannot** work out for itself: the numerator folds every
 * surface node, and the denominator is published only when a route advertises one, so it can sit
 * outside whatever window the phone holds. The reference UI does the same arithmetic
 * (`ui-conversation/src/client/context-occupancy.ts:15-25`): `projectedTokens ?? pressureTokens`
 * over `contextWindow`, capped and rounded — nothing here re-derives what the host knows (§2.1).
 *
 * The halves come from **two independently registered keys** (`@deepseek-ai/dsh-token-meter`:
 * `contextPressure`, `contextBreakdown`, each on its own terms), and one cut of both carries two
 * rules: a missing numerator or denominator is "unknown", never 0%, so the client hides the row
 * (§3.1 决定 4, 判据 U2); and one water mark for both keys, the cut's `asOfSeq`, so no client can
 * pair a fresh ratio with a stale breakdown (§3.1 决定 6, 判据 U7).
 *
 * See docs/dev/protocol.md §4.4 for the wire shape; docs/dev/plans/M6-presentation-layer.md
 * §3.1 决定 3 for which read `asOfSeq` stamps, and why the conservative cached one is wrong.
 */

/**
 * The composition half: a heuristic system / tools / message split of the next request.
 * Deliberately **not** a decomposition of `usedTokens` — the estimator underprices CJK text and
 * JSON schemas, so the three never sum to the anchored numerator (§3.1 决定 6).
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
   * Present only when all three parts are known and not all zero; absence omits the expanded rows,
   * never the ratio (§3.1 决定 6).
   */
  breakdown?: BreakdownValues
}

/**
 * One water mark plus whatever is displayable at it. Absent `usage` is a statement, not a gap: a
 * client showing something older clears it.
 */
export interface UsageSnapshot {
  /** The cut these values were read at — the log's water mark, not a window bound. */
  asOfSeq: number
  usage?: UsagePayload
}

/**
 * Turn one cut of the projection values into the snapshot to send.
 *
 * A numerator is required (`projectedTokens` first, then `pressureTokens`), so is a positive
 * `contextWindow`, and both must be integers: the projection's own schema says so, and a bad value
 * must not reach a percentage (§3.1 决定 4, 判据 U4).
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
 * Three types carry them (`dsh-token-meter`'s `usage-projection.ts`): `assistant/message` and
 * `assistant/attempt` contribute a usage sample (`usageOf`, `:82-86`, applied at `:128`);
 * `request/context` is the only source of `contextWindow` (`:181-191`).
 *
 * ⚠️ Upstream distinguishes two usage shapes (`data.usage`, or the last chunk of `data.stream`);
 * this deliberately does not: re-reading is an in-memory synchronous read that sends nothing when
 * nothing changed, and telling the shapes apart would only add a way to miss a sample
 * (§3.1 决定 3, 判据 U5).
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
 * Changed values travel, unchanged ones must not (a busy turn settles several times), and a payload
 * that became absent is a change like any other — it tells the client to stop showing the old
 * number (§3.1 决定 3, 判据 U3).
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
 * The three parts, or nothing: all three are required together (a partial split would mislead more
 * than it informs), and three zeros are as good as absent — an untouched session has nothing to
 * expand (§3.1 决定 6, 判据 U8).
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
