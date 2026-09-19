/**
 * The DSH adapter: the only module that knows the session store exists.
 *
 * It implements the seam's `SessionPort` on top of the host's own services, so
 * `rpc.ts` stays free of both DSH and I/O. The adapter declares only the shapes
 * it actually uses rather than importing the real types: this module lives
 * outside the dsh installation, where a bare specifier such as
 * `@deepseek-ai/dsh-session-persistence` does not resolve (verified:
 * MODULE_NOT_FOUND — no `node_modules` in any parent directory).
 *
 * ## The list is zero-I/O (v2), and here is what that costs
 *
 * v1 built each row by opening the session log and reading it whole — O(sessions)
 * full reads per list. v2 does not read a log at all:
 *
 * - **records**: the corpus lists every session as a header plus "is it live",
 *   without touching the stored bodies;
 * - **values**: a live session's projection comes from memory (real time), a cold
 *   session's from the durable checkpoint the host already maintains;
 * - **missing is missing**: when no projection is available the row simply has no
 *   `title` and `updatedAt` falls back to `createdAt`. It never reaches for the
 *   log to fill a cell in.
 *
 * The price is that the list promises less. `updatedAt` now means "the last time
 * you spoke" instead of "the newest event", and an event count is not promised at
 * all — because a field that can only be computed from a log cannot also be
 * served without reading one (docs/protocol.md §4.1). Those are contract changes,
 * so the protocol went to v2.
 *
 * ## Why one visibility rule lives here
 *
 * `cwd === undefined` skips a session the reference list also hides. The other
 * rules (subagent, archived, blank) belong to the client, so only this one — a
 * fact the header already carries — is applied here.
 */
import type { SessionPort, SessionRow, SessionSlice, WireEvent } from '../seam/rpc.ts'

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
 * One session's projection values, keyed by projection name.
 *
 * The shape belongs to the host (`title`, `sessionListMetadata`, …) and stays
 * opaque here: this file reads the two cells it needs and ignores the rest, so a
 * projection added upstream tomorrow cannot break the list.
 */
export type ProjectionValues = Readonly<Record<string, unknown>>

/**
 * Where one list row's raw material comes from.
 *
 * Four narrow methods rather than the services themselves: the branch between a
 * live and a cold session is the adapter's decision (and is tested), while how
 * each value is obtained is the host's business.
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
}

/** The cells this adapter reads out of `sessionListMetadata`. */
interface SessionListMetadataLike {
  readonly blank?: boolean
  readonly lastPromptAt?: number | null
}

/**
 * Build the session port over the host's services.
 * @param persistence - reads session logs, for `snapshot` and `page`.
 * @param listing - the list path's material (headers, projections, liveness).
 * @returns the port `handle()` reads through.
 */
export function createSessionPort(persistence: PersistenceLike, listing: ListSource): SessionPort {
  return {
    async list(): Promise<readonly SessionRow[]> {
      const rows: SessionRow[] = []
      for (const record of await listing.records()) {
        // Hidden the same way the reference list hides it — and skipped *before*
        // any projection lookup, so an invisible session costs nothing.
        if (record.header.cwd === undefined) continue

        const values = valuesFor(record, listing)
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
      return rows
    },

    async read(id: string, since: number, limit: number): Promise<SessionSlice | undefined> {
      let handle: HandleLike
      try {
        handle = await persistence.open(id, 'read')
      } catch (error) {
        // A missing session is a normal answer (`unknown-session`), not a fault.
        // Every other open failure — a format this build refuses, corruption,
        // ownership trouble — propagates and becomes a refusal at the seam.
        if ((error as { name?: unknown } | null)?.name === 'SessionPersistenceNotFoundError') return undefined
        throw error
      }

      try {
        // One event past the cap: its presence is what proves there is more,
        // so the seam never has to guess where the log ends.
        const { events } = await handle.read(since, limit + 1)

        if (events.length === 0 && since > 0) {
          // Caught up, or a cursor past the end? Only the log can tell them
          // apart, and only for the case it can actually prove: an empty log
          // cannot contain position 1. A `since` merely beyond the water mark is
          // indistinguishable from "caught up" from here and stays a normal
          // empty answer (docs/protocol.md §五, docs/plans/M1-consistency-delta.md
          // §3.3.2 决定 5).
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
 * Where one record's projection comes from.
 *
 * The branch is the whole reason a running session stays current while a finished
 * one can be served from disk: a live session's values are in memory and move as
 * it works; a finished session's log no longer changes, so its last checkpoint is
 * the final answer rather than a stale one.
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
 * The title cell, as an optional wire field.
 *
 * Anything that is not a string — including the `null` a title-less session
 * carries — means "no title", so the field is absent rather than empty
 * (docs/protocol.md §4.1).
 */
function titleOf(values: ProjectionValues | undefined): { title?: string } {
  const cell = values?.title
  return typeof cell === 'string' ? { title: cell } : {}
}

/**
 * The row's activity time: the last user prompt, never before creation.
 *
 * Deliberately not "the newest event's time". That value needs the log, and not
 * needing the log is the entire point of v2's list.
 */
function lastPromptAt(header: HeaderLike, metadata: SessionListMetadataLike | undefined): number {
  const promptAt = metadata?.lastPromptAt
  return typeof promptAt === 'number' ? Math.max(header.createdAt, promptAt) : header.createdAt
}
