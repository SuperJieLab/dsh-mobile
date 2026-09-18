/**
 * The DSH adapter: the only module that knows the session store exists.
 *
 * It implements the seam's `SessionPort` on top of `ctx.sessionPersistence`, so
 * `rpc.ts` stays free of both DSH and I/O. The adapter declares only the shape
 * it actually uses (`PersistenceLike` below) rather than importing the real
 * types: this module lives outside the dsh installation, where a bare specifier
 * such as `@deepseek-ai/dsh-session-persistence` does not resolve (verified:
 * MODULE_NOT_FOUND — no `node_modules` in any parent directory).
 *
 * ## The cost this file accepts
 *
 * `list()` opens and fully reads every session log, because the cheap metadata
 * path cannot supply what the protocol promises: the jsonl backend's
 * `stat`/`list` return only `{ header, revision, sizeBytes }` — no `eventCount`,
 * no title, and no `updatedAt` (the header carries `createdAt` only). Titles live
 * inside the log as latest-wins `session/title` events, and `updatedAt` is the
 * last event's `time`. So the list is O(sessions) full log reads, and a large
 * store makes it visibly slow.
 *
 * That cost is deliberate and recorded in docs/plans/M1-lan-mvp.md §4.3 Step 3:
 * it is the concrete motivation for a projection or index, which is exactly the
 * ground M2/M3 cover. The honest alternative — dropping `title`/`updatedAt`/
 * `eventCount` from the protocol — was rejected because M1's client would then
 * show a list of opaque ids.
 */
import type { SessionPort, SessionSummary, SessionSlice, WireEvent } from './rpc.ts'

/** The header fields this adapter reads. */
interface HeaderLike {
  readonly id: string
  readonly createdAt: number
}

/** What `SessionPersistence.list()` yields — one entry per stored session. */
interface SnapshotLike {
  readonly header: HeaderLike
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
  list(): Promise<readonly SnapshotLike[]>
  open(id: string, access: 'read'): Promise<HandleLike>
}

/** The DSH event type whose latest occurrence carries the current title. */
const TITLE_EVENT_TYPE = 'session/title'

/**
 * Build the session port over a DSH persistence service.
 * @param persistence - the injected `ctx.sessionPersistence` service.
 * @returns the port `handle()` reads through.
 */
export function createSessionPort(persistence: PersistenceLike): SessionPort {
  return {
    async list(): Promise<readonly SessionSummary[]> {
      const snapshots = await persistence.list()
      const summaries: SessionSummary[] = []
      for (const snapshot of snapshots) {
        const summary = await summarise(persistence, snapshot.header)
        if (summary !== undefined) summaries.push(summary)
      }
      return summaries
    },

    async read(id: string, since: number): Promise<SessionSlice | undefined> {
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
        const { events } = await handle.read(since)
        const last = events.at(-1)
        return { events, asOfSeq: last === undefined ? since : last.seq + 1 }
      } finally {
        await handle.close().catch(() => {})
      }
    },
  }
}

/**
 * Derive one list row from a log.
 *
 * A session whose log cannot be read is skipped rather than failing the whole
 * list: one unreadable or corrupt log must not make every other session
 * invisible. The skip is loud on stderr because a silently missing session is
 * the worst outcome for a client that has no other way to notice.
 * @returns the summary, or `undefined` when this session's log is unreadable.
 */
async function summarise(persistence: PersistenceLike, header: HeaderLike): Promise<SessionSummary | undefined> {
  let handle: HandleLike | undefined
  try {
    handle = await persistence.open(header.id, 'read')
    const { events } = await handle.read()
    const title = titleOf(events)
    return {
      id: header.id,
      ...title === undefined ? {} : { title },
      createdAt: header.createdAt,
      // An empty log has no last event; creation time is then the only fact.
      updatedAt: events.at(-1)?.time ?? header.createdAt,
      eventCount: events.length,
    }
  } catch (error) {
    console.error(`[mac-gateway] skipping session ${header.id}: ${String(error)}`)
    return undefined
  } finally {
    await handle?.close().catch(() => {})
  }
}

/**
 * The current title, or `undefined` when there is none.
 *
 * Latest wins, so the scan runs backwards and stops at the first title event.
 * The payload is treated as data of unknown shape: a title event whose `title`
 * is not a string means "no title", not a crash.
 */
function titleOf(events: readonly WireEvent[]): string | undefined {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event?.type !== TITLE_EVENT_TYPE) continue
    const payload = event.data as { title?: unknown } | null | undefined
    return typeof payload?.title === 'string' ? payload.title : undefined
  }
  return undefined
}
