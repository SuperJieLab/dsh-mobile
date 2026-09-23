/**
 * The DSH adapter: the only module that knows the session store exists.
 *
 * It implements the contract's `SessionPort` over the host's services, so `rpc.ts` stays free
 * of both DSH and I/O, and declares its own shapes because the real types do not resolve outside
 * the dsh installation (`@deepseek-ai/dsh-session-persistence`: MODULE_NOT_FOUND).
 *
 * ## The list is zero-I/O (v2)
 *
 * v1 read each log whole (O(sessions) full reads); v2 reads no log. Records are a header
 * plus "is it live"; values come from memory when live and the durable checkpoint when
 * cold; a missing projection stays missing — no `title`, `updatedAt` falls back to
 * `createdAt`, never a log read to fill a cell.
 *
 * The price: `updatedAt` means "the last time you spoke", not "the newest event", and no
 * event count is promised (docs/dev/protocol.md §4.1) — a field computable only from a log
 * cannot also be served without reading one. Hence v2.
 *
 * `cwd === undefined` skips a session the reference list also hides; the other rules
 * (subagent, archived, blank) are the client's, and this one is already a header fact.
 */
import type { SessionPort, SessionRow, SessionSlice, WireEvent } from '../contract/rpc.ts'

/** The header fields this adapter reads. */
interface HeaderLike {
  readonly id: string
  readonly createdAt: number
  /** Absent means the session is not shown as an ordinary workspace session. */
  readonly cwd?: string
  /**
   * A seeded log inherits a prefix from another session, and a checkpoint's
   * identity is bound to that exact prefix — which a header alone does not name.
   * So a seeded session is served from its header, never from the cache.
   */
  readonly isSeeded?: boolean
  /** `'subagent'` for a child session; absent for an ordinary one. */
  readonly origin?: string
}

/** What `SessionHandle.read()` yields. */
interface ReadResultLike {
  readonly events: readonly WireEvent[]
}

/** The part of `SessionHandle` this adapter uses. */
interface HandleLike {
  read(offset?: number, length?: number): Promise<ReadResultLike>
  close(): Promise<void>
}

/** The part of `SessionPersistence` this adapter uses. */
export interface PersistenceLike {
  open(id: string, access: 'read'): Promise<HandleLike>
}

/** One record as the corpus yields it. */
export interface ListRecord {
  readonly header: HeaderLike
  /** Whether this session is currently live in memory. */
  readonly live: boolean
}

/**
 * One session's projection values, keyed by projection name. The shape belongs to the host
 * (`title`, `sessionListMetadata`, …) and stays opaque here: this file reads the two cells it
 * needs and ignores the rest, so a projection added upstream tomorrow cannot break the list.
 */
export type ProjectionValues = Readonly<Record<string, unknown>>

/**
 * Where one list row's raw material comes from: four narrow methods rather than the services
 * themselves, because the live/cold branch is the adapter's decision (and is tested), while how
 * each value is obtained is the host's.
 */
export interface ListSource {
  /** Every session, as a header plus its liveness. */
  records(): Promise<readonly ListRecord[]>
  /** A live session's projection, straight from memory. */
  liveValues(sessionId: string): ProjectionValues | undefined
  /** A cold session's projection, from the durable checkpoint. */
  storedValues(header: HeaderLike): ProjectionValues | undefined
  /** Whether an agent is running for this session right now. */
  isRunning(sessionId: string): boolean
  /**
   * Called once per `list()` when one or more rows went out without their projection cells —
   * the count is handed back to whoever assembles this source rather than swallowed here,
   * because silent degradation is how a drifted upstream call stays invisible.
   */
  onProjectionFailure?(failures: number, first: unknown): void
}

/** The cells this adapter reads out of `sessionListMetadata`. */
interface SessionListMetadataLike {
  readonly blank?: boolean
  readonly lastPromptAt?: number | null
}

/**
 * Build the session port over the host's services: `persistence` reads logs (for `snapshot`
 * and `page`), `listing` supplies the list path's material, and the returned port is what
 * `handle()` reads through.
 */
export function createSessionPort(persistence: PersistenceLike, listing: ListSource): SessionPort {
  return {
    async list(): Promise<readonly SessionRow[]> {
      const rows: SessionRow[] = []
      let failures = 0
      let firstFailure: unknown
      for (const record of await listing.records()) {
        // Hidden the same way the reference list hides it, and skipped *before* any projection
        // lookup — an invisible session costs nothing.
        if (record.header.cwd === undefined) continue

        let values: ProjectionValues | undefined
        try {
          values = valuesFor(record, listing)
        } catch (error) {
          // A projection is a *hint*: one row's read failing costs that row its cells, never
          // the whole list — the line upstream's listing draws (`session-controller/src/list.ts`
          // `projectionsFor`, returns `undefined` and warns). Without it one unreadable
          // checkpoint blanks the screen (实施期修正 16).
          failures += 1
          firstFailure ??= error
        }

        const metadata = metadataOf(values)
        rows.push({
          id: record.header.id,
          ...titleOf(values),
          createdAt: record.header.createdAt,
          updatedAt: lastPromptAt(record.header, metadata),
          running: listing.isRunning(record.header.id),
          blank: metadata?.blank === true,
          ...record.header.origin === undefined ? {} : { origin: record.header.origin },
        })
      }
      if (failures > 0) listing.onProjectionFailure?.(failures, firstFailure)
      return rows
    },

    async read(id: string, since: number, limit: number): Promise<SessionSlice | undefined> {
      let handle: HandleLike
      try {
        handle = await persistence.open(id, 'read')
      } catch (error) {
        // A missing session is a normal answer (`unknown-session`), not a fault. Every
        // other open failure propagates and becomes a refusal at the contract.
        if ((error as { name?: unknown } | null)?.name === 'SessionPersistenceNotFoundError') return undefined
        throw error
      }

      try {
        // One event past the cap: its presence proves there is more, so the contract never
        // has to guess where the log ends.
        const { events } = await handle.read(since, limit + 1)

        if (events.length === 0 && since > 0) {
          // Caught up, or a cursor past the end? Only the log can tell, and only what it
          // can prove: an empty log cannot contain position 1. A `since` merely past the
          // water mark is indistinguishable from "caught up" and stays a normal empty
          // answer (docs/dev/protocol.md §五,
          // docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 5).
          const head = await handle.read(0, 1)
          if (head.events.length === 0) {
            return { events: [], asOfSeq: 0, hasMore: false, staleCursor: true }
          }
        }

        const hasMore = events.length > limit
        const kept = hasMore ? events.slice(0, limit) : events
        const last = kept.at(-1)
        return { events: kept, asOfSeq: last === undefined ? since : last.seq + 1, hasMore, staleCursor: false }
      } finally {
        await handle.close().catch(() => {})
      }
    },

    async readAll(id: string): Promise<readonly WireEvent[] | undefined> {
      let handle: HandleLike
      try {
        handle = await persistence.open(id, 'read')
      } catch (error) {
        if ((error as { name?: unknown } | null)?.name === 'SessionPersistenceNotFoundError') return undefined
        throw error
      }

      try {
        return (await handle.read()).events
      } finally {
        await handle.close().catch(() => {})
      }
    },
  }
}

/**
 * Where one record's projection comes from: memory for a live session (its values move as it
 * works), the durable checkpoint for a finished one (its log no longer changes, so the checkpoint
 * is final, not stale). May throw; callers degrade the row rather than the list (see `list`).
 */
function valuesFor(record: ListRecord, listing: ListSource): ProjectionValues | undefined {
  if (record.live) return listing.liveValues(record.header.id)
  if (record.header.isSeeded === true) return undefined
  return listing.storedValues(record.header)
}

/** The `sessionListMetadata` cell, when the projection carried a usable one. */
function metadataOf(values: ProjectionValues | undefined): SessionListMetadataLike | undefined {
  const cell = values?.sessionListMetadata
  if (typeof cell !== 'object' || cell === null) return undefined
  return cell as SessionListMetadataLike
}

/**
 * The title cell: anything not a string — including the `null` a title-less session carries —
 * means "no title", so the field is absent rather than empty (docs/dev/protocol.md §4.1).
 */
function titleOf(values: ProjectionValues | undefined): { title?: string } {
  const cell = values?.title
  return typeof cell === 'string' ? { title: cell } : {}
}

/**
 * The row's activity time: the last user prompt, never before creation — deliberately not "the
 * newest event's time", which would need the log the v2 list exists to avoid.
 */
function lastPromptAt(header: HeaderLike, metadata: SessionListMetadataLike | undefined): number {
  const promptAt = metadata?.lastPromptAt
  return typeof promptAt === 'number' ? Math.max(header.createdAt, promptAt) : header.createdAt
}
