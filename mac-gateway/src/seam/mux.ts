/**
 * The stream seam: the mux framing and the follow opening, as pure functions.
 *
 * This layer owns everything about the new transport that is NOT a protocol
 * message: the frame envelope (which carries `streamId` and nothing else), the
 * follow request's shape, and the window assembly the opening frame serves.
 * Everything that IS a protocol message — records, events, error objects — is
 * produced by `rpc.ts` and passed through here **verbatim**: that pass-through
 * is the executable form of "the same messages, one word unchanged, on the new
 * carrier" (docs/plans/M2-realtime-transient.md §3.3).
 *
 * Frame shapes mirror the reference mux exactly (upstream `stream-protocol.ts`,
 * pinned at `0d1f5000`): a client sends `{type:'open'|'cancel', streamId,
 * payload}`, the server answers `{type:'item'|'end'|'error', streamId, payload}`.
 * One logical stream is one AsyncIterable; there is no request/response
 * correlation to get wrong. The HTTP envelope's `{v, op, ok}` shell does not
 * enter this channel — a stream has no reply to mark ok, and the version gate
 * lives in the `mux v1` framing contract instead (docs/plans/M2-realtime-transient.md
 * §3.3, "the precise scope of 'word for word'").
 *
 * The opening's records share `pageWindow` with `page` (rpc.ts) — one window
 * function, so "the follow opening is the same window a `page` returns" is a
 * structural fact, not a promise to keep in sync.
 *
 * See docs/plans/M2-realtime-transient.md §3.2/§3.3/§4.4.
 */

import { pageWindow, type WireEvent } from './rpc.ts'

/** The one framing version this build speaks. */
export const MUX_VERSION = 1

/** Client → server: begin one logical stream. */
export interface MuxOpenFrame {
  type: 'open'
  streamId: number
  payload: unknown
}

/** Client → server: stop one logical stream. */
export interface MuxCancelFrame {
  type: 'cancel'
  streamId: number
}

/** Everything a client can send on the mux connection. */
export type MuxClientFrame = MuxOpenFrame | MuxCancelFrame

/** Server → client: one item of the stream (an opening, an event, a transient frame). */
export interface MuxItemFrame {
  type: 'item'
  streamId: number
  payload: unknown
}

/** Server → client: the stream ended normally. */
export interface MuxEndFrame {
  type: 'end'
  streamId: number
}

/** Server → client: the stream failed; `payload` is the protocol's error object. */
export interface MuxErrorFrame {
  type: 'error'
  streamId: number
  payload: { code: string; message: string }
}

/** Server → client: a connection-level approval push (M5, 实施期修正 11). */
export interface MuxApprovalFrame {
  type: 'approval'
  /** `{kind:'request', eventId, toolName, callId?, reason?}` or `{kind:'cancel', eventId}`. */
  payload: unknown
}

/** Everything the server sends on the mux connection. */
export type MuxServerFrame = MuxItemFrame | MuxEndFrame | MuxErrorFrame | MuxApprovalFrame

/**
 * Parse one client frame from its wire text.
 *
 * @returns `undefined` for anything that is not a well-formed client frame —
 *   unparsable JSON, an unknown `type`, a non-integral `streamId`, or an `open`
 *   whose payload is not a follow request. The caller answers `undefined` with
 *   a transport-level close, not a protocol error frame: a thing that cannot be
 *   parsed is not a message and has no stream to be refused on.
 */
export function parseClientFrame(text: string): MuxClientFrame | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined
  const frame = parsed as Record<string, unknown>
  if (!isIntegral(frame.streamId)) return undefined

  if (frame.type === 'cancel') return { type: 'cancel', streamId: frame.streamId as number }

  if (frame.type === 'open') {
    return followRequestOf(frame.payload) === undefined
      ? undefined
      : { type: 'open', streamId: frame.streamId as number, payload: frame.payload }
  }

  return undefined
}

/** Encode one server frame to its wire text. */
export function encodeServerFrame(frame: MuxServerFrame): string {
  return JSON.stringify(frame)
}

/**
 * The follow request carried by an `open` payload.
 *
 * Deliberately small — the reference request is `{address, maxMessages?,
 * assistantStream?}` (upstream `types.ts:449`), and the notable absence is a
 * water mark: a reconnect re-opens and rebuilds its window from the new opening
 * rather than resuming from a cursor (docs/plans/M2-realtime-transient.md §3.4).
 */
export interface FollowRequest {
  sessionId: string
  /** Window size for the opening; absent = the default, same as `page`. */
  maxMessages?: number
}

/**
 * Validate an `open` payload as a follow request.
 *
 * The op set is shared with the HTTP envelope by name and meaning; M2 adds
 * exactly one op, `follow` (docs/plans/M2-realtime-transient.md §3.3). A
 * payload naming any other op — or none — is not a follow request and comes
 * back `undefined`.
 *
 * @returns the request, or `undefined` when it cannot name a session — the
 *   same leniency boundary as `page`: a malformed `maxMessages` degrades to the
 *   default (the worst case is one window the caller did not need), but a
 *   payload without a usable `sessionId` is not a follow request at all.
 */
export function followRequestOf(payload: unknown): FollowRequest | undefined {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return undefined
  const record = payload as Record<string, unknown>
  if (record.op !== 'follow') return undefined
  const sessionId = record.sessionId
  if (typeof sessionId !== 'string' || sessionId === '') return undefined
  return isPositiveInteger(record.maxMessages)
    ? { sessionId, maxMessages: record.maxMessages as number }
    : { sessionId }
}

/** The opening frame's payload: a `page`-shaped window plus the stream's anchors. */
export interface FollowOpening {
  sessionId: string
  /**
   * The exclusive upper bound the log had reached when the opening was cut —
   * the position the event frames that follow start *after*. Present so the
   * client can state "everything from here on arrived live" without comparing
   * window contents.
   */
  cursor: number
  /** First seq of the window — the client's next `beforeSeq` when paging back. */
  pageStart: number
  /** Same field, same meaning as in a `page` reply. */
  hasOlder: boolean
  /** The window — serialized identically to a `page` reply's `events`. */
  events: readonly WireEvent[]
  /**
   * The transient baseline, carried through verbatim when one is live: an
   * in-progress assistant attempt with its accumulated text and next chunk
   * index. Opaque here — the client's `TransientChannel` owns its semantics
   * (docs/plans/M2-realtime-transient.md §3.4); the seam only promises that
   * what the source gave arrives unchanged.
   */
  assistantStream?: unknown
}

/**
 * Assemble a follow opening from one session's whole log.
 *
 * The whole-log input is the same price `page` already pays (the stored-read
 * API walks forward only), and it is what makes the window assembly identical
 * to a `page`'s: same function, same density precondition, same boundary rule.
 *
 * @throws the errors {@link pageWindow} throws — the adapter turns them into an
 *   `error` frame carrying the same code a `page` would have refused with.
 */
export function followOpening(request: FollowRequest, events: readonly WireEvent[]): FollowOpening {
  const window = pageWindow(request.sessionId, events, undefined, request.maxMessages ?? DEFAULT_FOLLOW_MESSAGES)
  return {
    sessionId: request.sessionId,
    cursor: window.asOfSeq,
    pageStart: window.pageStart,
    hasOlder: window.hasOlder,
    events: window.events,
  }
}

/**
 * Window size for a follow opening when the caller does not say — the same
 * default a `page` uses, because the opening IS the first page.
 */
export const DEFAULT_FOLLOW_MESSAGES = 50

function isIntegral(value: unknown): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value)
}

function isPositiveInteger(value: unknown): boolean {
  return isIntegral(value) && (value as number) > 0
}
