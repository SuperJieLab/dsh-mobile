/**
 * The stream adapter: WebSocket upgrade on our own listener, and the pump that
 * turns the session controller's follow stream into mux frames.
 *
 * The upgrade hangs off the listener this plugin starts itself (`'upgrade'`
 * event, same port as `POST /rpc`) — `ctx.webServer` is not an option here: it
 * is a host-global setting whose CLI refuses `0.0.0.0`, and M0 exists precisely
 * because of that (docs/plans/M0-reachability-spike.md §3.2). The reference
 * gateway's `registerUpgrade` is the same idea played on the host's server; ours
 * is the same idea played on ours.
 *
 * The pump's contract to the wire (docs/plans/M2-realtime-transient.md §3.3):
 * the reference follow frames wrap every event as `{type:'event', event}` —
 * the unwrap is the whole conversion. The opening's window arrives already cut
 * by the source's own pagination (the same message-count rule our `page` was
 * modelled on), so the adapter carries it through with only shape changes:
 * records unwrap to the event objects, the inclusive cursor becomes our
 * exclusive one. Event frames pass the DSH event object through **verbatim**;
 * transient frames pass through verbatim too, cursor-less. What this adapter
 * adds is only what the transport owes: framing, the heartbeat, seq-continuity
 * witnessing (the source promises gap-free; we refuse loudly if it ever lies —
 * §3.5), and error mapping.
 *
 * See docs/plans/M2-realtime-transient.md §3.2/§4.4 step 3.
 */

import type { Duplex, IncomingMessage, Server } from 'node:http'
import {
  encodeServerFrame,
  followRequestOf,
  parseClientFrame,
  type MuxServerFrame,
} from '../seam/mux.ts'
import {
  WsFrameParser,
  acceptKeyOf,
  encodeClose,
  encodePing,
  encodePong,
  encodeTextFrame,
  handshakeResponse,
} from '../seam/ws-frames.ts'

/**
 * The stream source this adapter is written against — the narrow face of
 * `ctx.sessionController` the pump uses, declared here because the service's
 * real type does not resolve from outside the dsh installation.
 */
export interface FollowSource {
  follow(
    request: { address: { kind: 'session'; sessionId: string }; maxMessages?: number; assistantStream: true },
    signal: AbortSignal,
  ): AsyncIterable<UpstreamFollowFrame>
}

/**
 * One frame of the reference follow stream, as far as this adapter cares.
 *
 * Shapes verified at `0d1f5000` (`history.ts:119-240`): an opening `snapshot`
 * whose `records` wrap each event as `{type:'event', event}`, then `event`
 * frames in the same wrapping, then cursor-less `assistant-stream` frames.
 */
export type UpstreamFollowFrame =
  | {
      type: 'snapshot'
      /** Last seq the opening covers, inclusive; `-1` for an empty log. */
      cursor: number
      records: readonly { type: 'event'; event: unknown }[]
      /** Whether older events exist before the window (the reference's `hasMore`). */
      hasMore: boolean
      assistantStream?: unknown
    }
  | { type: 'event'; event: unknown }
  | { type: 'assistant-stream'; frame: unknown }

/** Heartbeat cadence, matching the reference server: a ping every 2 s. */
const PING_INTERVAL_MS = 2_000

/** A client that misses this many consecutive pongs is gone; close the socket. */
const MISSED_PONG_LIMIT = 2

/** The exact path this gateway serves its stream protocol on. */
export const STREAM_PATH = '/rpc/stream'

/**
 * Hang the stream protocol off the plugin's own listener.
 *
 * The handler owns negotiation (verified against the handshake key) and the
 * socket afterwards. Everything a socket does is best-effort with errors
 * swallowed at the socket boundary: a dead client is routine, not a fault.
 *
 * `gate` is the M4 auth gate: checked once at upgrade, before the handshake is
 * answered — no live access token, no 101. A connection that got through stays
 * up even after its token expires: re-authentication happens on the next
 * connect, not mid-stream (docs/plans/M4-identity-credentials.md §3.3).
 */
export function attachStreamHandler(
  server: Server,
  source: FollowSource,
  gate: { authenticate(authorizationHeader: string | undefined): boolean },
): void {
  server.on('upgrade', (request, socket, head) => {
    void handleUpgrade(request, socket, head, source, gate)
  })
}

async function handleUpgrade(
  request: IncomingMessage,
  socket: Duplex,
  head: Buffer,
  source: FollowSource,
  gate: { authenticate(authorizationHeader: string | undefined): boolean },
): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://gateway').pathname
  console.log(`[mac-gateway] upgrade request for "${path}"`)
  if (path !== STREAM_PATH) {
    // Not ours — decline without pretending to speak WebSocket.
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n')
    socket.destroy()
    return
  }

  if (!gate.authenticate(request.headers.authorization)) {
    console.log('[mac-gateway] upgrade refused: no valid access token')
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n')
    socket.destroy()
    return
  }

  const accept = acceptKeyOf(request.headers)
  if (accept === undefined) {
    console.log('[mac-gateway] upgrade refused: no Sec-WebSocket-Key')
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n')
    socket.destroy()
    return
  }

  console.log('[mac-gateway] upgrade accepted → 101')
  socket.write(handshakeResponse(accept))
  runSocket(socket, source, head)
}

/** Per-connection state and loop. */
function runSocket(socket: Duplex, source: FollowSource, head: Buffer): void {
  const parser = new WsFrameParser()
  const streams = new Map<number, { abort: AbortController }>()

  // Heartbeat: a ping every 2 s; two consecutive misses end the connection.
  // The reference server terminates on the same budget (`stream-server.ts`).
  let unansweredPings = 0
  const heartbeat = setInterval(() => {
    unansweredPings += 1
    if (unansweredPings > MISSED_PONG_LIMIT) {
      socket.destroy()
      return
    }
    write(socket, encodePing())
  }, PING_INTERVAL_MS)

  const closeAll = (): void => {
    clearInterval(heartbeat)
    for (const stream of streams.values()) stream.abort.abort()
    streams.clear()
  }

  const onChunk = (chunk: Buffer): void => {
    const { frames, error } = parser.push(chunk)
    if (error !== undefined) {
      // A peer breaking framing is not speaking this protocol; there is no
      // frame to send and no stream to name. Close.
      socket.destroy()
      return
    }
    for (const frame of frames) {
      switch (frame.kind) {
        case 'pong':
          unansweredPings = 0
          break
        case 'ping':
          write(socket, encodePong(frame.payload))
          break
        case 'close':
          write(socket, encodeClose())
          socket.end()
          break
        case 'text':
          onClientText(socket, source, streams, frame.text)
          break
      }
    }
  }

  // Frames may ride the upgrade request's final bytes.
  if (head.length > 0) onChunk(head)
  socket.on('data', onChunk)
  socket.on('close', closeAll)
  socket.on('error', closeAll)
}

/**
 * Route one parsed client text frame: an `open` starts a pump, a `cancel`
 * stops one. The seam's parser has already refused everything that is not a
 * well-formed client frame, so what survives to here is shape-checked.
 */
function onClientText(
  socket: Duplex,
  source: FollowSource,
  streams: Map<number, { abort: AbortController }>,
  text: string,
): void {
  const frame = parseClientFrame(text)
  if (frame === undefined) return

  if (frame.type === 'cancel') {
    const stream = streams.get(frame.streamId)
    if (stream !== undefined) {
      stream.abort.abort()
      streams.delete(frame.streamId)
    }
    return
  }

  // frame.type === 'open'
  if (streams.has(frame.streamId)) return // an id in use is not re-opened; the client owns ids

  const request = followRequestOf(frame.payload)
  if (request === undefined) {
    send(socket, { type: 'error', streamId: frame.streamId, payload: { code: 'unknown-op', message: 'open payload is not a follow request' } })
    return
  }

  const abort = new AbortController()
  streams.set(frame.streamId, { abort })
  void pump(socket, source, frame.streamId, request, abort.signal, () => streams.delete(frame.streamId))
}

/**
 * Pump one follow stream: opening first, then events, until the source ends,
 * the client cancels, or the source breaks its own contract.
 */
async function pump(
  socket: Duplex,
  source: FollowSource,
  streamId: number,
  request: { sessionId: string; maxMessages?: number },
  signal: AbortSignal,
  done: () => void,
): Promise<void> {
  const sendItem = (payload: unknown): void => {
    send(socket, { type: 'item', streamId, payload })
  }

  try {
    const iterable = source.follow({
      address: { kind: 'session', sessionId: request.sessionId },
      maxMessages: request.maxMessages,
      assistantStream: true,
    }, signal)

    let expectedSeq: number | undefined // next event seq, from the opening's cursor
    let transientCount = 0

    for await (const frame of iterable) {
      if (signal.aborted) return

      if (frame.type === 'snapshot') {
        // The window is already cut by the source's own pagination — the same
        // message-count rule `page` was modelled on. Unwrap it; do not re-cut.
        const events = frame.records.map(record => record.event)
        const first = events[0] as { seq?: unknown } | undefined
        const cursor = frame.cursor + 1 // reference cursor is inclusive; ours is exclusive
        expectedSeq = cursor
        console.log(`[mac-gateway] follow opening for "${request.sessionId}": cursor=${cursor}, ${events.length} events`)
        sendItem({
          sessionId: request.sessionId,
          cursor,
          pageStart: typeof first?.seq === 'number' ? first.seq : cursor,
          hasOlder: frame.hasMore,
          events,
          ...(frame.assistantStream === undefined ? {} : { assistantStream: frame.assistantStream }),
        })
        continue
      }

      if (frame.type === 'event') {
        const event = frame.event as { seq?: unknown } | undefined
        // The source promises gap-free; we witness it. A skipped seq means the
        // stream's own promise broke — refuse loudly rather than render a view
        // with a hole nobody can see (docs/plans/M2-realtime-transient.md §3.5).
        if (expectedSeq !== undefined && event?.seq !== expectedSeq) {
          console.error(`[mac-gateway] follow stream broke continuity: expected seq ${String(expectedSeq)}, got ${String(event?.seq)}`)
          send(socket, { type: 'error', streamId, payload: { code: 'internal-error', message: `follow stream skipped seq ${String(expectedSeq)}` } })
          return
        }
        if (typeof event?.seq === 'number') expectedSeq = event.seq + 1
        sendItem(event) // verbatim — the protocol message IS the event object
        continue
      }

      if (frame.type === 'assistant-stream') {
        transientCount += 1
        if (transientCount === 1 || transientCount % 50 === 0) {
          console.log(`[mac-gateway] transient frames forwarded: ${transientCount}`)
        }
        sendItem({ type: 'assistant-stream', frame: frame.frame }) // verbatim, cursor-less
        continue
      }
    }

    send(socket, { type: 'end', streamId })
  } catch (error) {
    if (!signal.aborted) {
      send(socket, { type: 'error', streamId, payload: mapError(error) })
    }
  } finally {
    done()
  }
}

/**
 * Map a source failure to the protocol's error object, with the same code the
 * HTTP path would have refused with: a log this runtime cannot interpret is
 * `unreadable-session`, a session the source does not know is
 * `unknown-session`, everything else is ours.
 */
function mapError(error: unknown): { code: string; message: string } {
  const name = (error as { name?: unknown } | null)?.name
  if (name === 'SessionFormatUnsupportedError' || name === 'SessionPersistenceCorruptionError') {
    return { code: 'unreadable-session', message: describe(error) }
  }
  const remote = error as { isDSHRemoteError?: boolean; code?: unknown }
  if (remote?.isDSHRemoteError === true && typeof remote.code === 'string' && remote.code.endsWith('/not-found')) {
    return { code: 'unknown-session', message: describe(error) }
  }
  return { code: 'internal-error', message: describe(error) }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function send(socket: Duplex, frame: MuxServerFrame): void {
  write(socket, encodeTextFrame(encodeServerFrame(frame)))
}

function write(socket: Duplex, buffer: Buffer): void {
  if (socket.destroyed) return
  socket.write(buffer)
}
