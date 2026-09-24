/**
 * The HTTP transport for the phone: route one request, enforce the transport
 * guards, and gate identity — everything a socket-level caller owes the protocol
 * but that is not itself protocol.
 *
 * Status codes are not protocol — the envelope carries the outcome, so a
 * protocol-level refusal is still HTTP 200. `/rpc` carries protocol messages;
 * the rest only tells a human "the listener is up" from "nothing is listening".
 */
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { createServer } from 'node:http'
import { DEFAULT_LIMITS, handle, PROTOCOL_VERSION, type Limits, type SessionPort } from '../contract/rpc.ts'
import type { WritePort } from '../contract/write-channel.ts'
import type { ModelPort } from '../contract/model-selection.ts'
import { CredentialVault } from './credentials.ts'

/** Request-body ceiling — a transport guard, not a protocol rule: the port is
 * LAN-reachable and an unbounded read is a memory-exhaustion lever. 1 MiB is far
 * above any v2 request. */
const MAX_BODY_BYTES = 1_048_576

/** What the listener needs to answer one request. */
export interface RpcListenerDeps {
  sessionPort: SessionPort
  limits: Limits
  vault: CredentialVault
  writePort: WritePort
  modelPort: ModelPort | undefined
}

/**
 * Build the plugin's own HTTP listener: one server, `POST /rpc` for one-way
 * calls, the stream upgrade sharing the port (gated like any request — no live
 * access token, no 101; see remote/ws.ts).
 */
export function createRpcListener(deps: RpcListenerDeps): Server {
  // `respond` never rejects; a throw here would be an unhandled rejection.
  return createServer((request, response) => {
    void respond(request, response, deps)
  })
}

/** Route one request. */
async function respond(
  request: IncomingMessage,
  response: ServerResponse,
  deps: RpcListenerDeps,
): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://gateway').pathname

  if (path !== '/rpc') {
    // Liveness, and the answer to any unknown path. Transport-level only: no
    // protocol message is involved, so no envelope is involved either.
    response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(path === '/' ? 'mac-gateway alive — M4, protocol v2, POST /rpc for the protocol\n' : 'not found\n')
    return
  }

  if (request.method !== 'POST') {
    response.writeHead(405, { 'content-type': 'text/plain; charset=utf-8', allow: 'POST' })
    response.end('use POST /rpc\n')
    return
  }

  let body: string
  try {
    body = await readBody(request)
  } catch (error) {
    // Not a message at all, so it is refused as a transport failure rather than
    // answered with a protocol envelope carrying a meaningless code.
    response.writeHead(error instanceof TooLargeError ? 413 : 400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  let message: unknown
  try {
    message = JSON.parse(body)
  } catch (error) {
    response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  // Identity (M4): the auth ops carry their credential in the body, every other
  // op needs a live access token; a denial is HTTP 401 with a protocol envelope.
  const op = (message as { op?: unknown } | null)?.op
  if (op === 'pair' || op === 'refresh') {
    const answer = await handleAuthOp(op, message, deps.vault)
    response.writeHead(answer.status, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(answer.body)}\n`)
    return
  }

  if (!deps.vault.authenticate(request.headers.authorization)) {
    response.writeHead(401, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(refusal('unauthenticated', 'missing or expired access token — pair first, then refresh'))}\n`)
    return
  }

  const answer = await handle(message, deps.sessionPort, Date.now, deps.limits, deps.writePort, deps.modelPort)
  // Refusals keep evidence server-side: write ops because the phone only shows a
  // status line, model ops because the T8 device run showed a silently-empty catalog
  // — a read op that dies must not be quieter than a write op that fails.
  if (!answer.ok && (op === 'session-prompt' || op === 'approval-answer' || op === 'model-select' || op === 'model-catalog')) {
    console.error(`[mac-gateway] op "${op}" refused: ${JSON.stringify(answer.error)}`)
  }
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${JSON.stringify(answer)}\n`)
}

/** Refusal envelope shared by the auth path (the read path builds its own inside `handle`). */
function refusal(code: string, message: string): { v: number; ok: false; error: { code: string; message: string } } {
  return { v: PROTOCOL_VERSION, ok: false, error: { code, message } }
}

/**
 * Answer `pair` / `refresh`. Kept beside the gate, not inside `handle`, so the
 * protocol contract stays a pure read protocol: these two are the only messages
 * whose authority comes from the body rather than the header.
 */
async function handleAuthOp(
  op: 'pair' | 'refresh',
  message: unknown,
  vault: CredentialVault,
): Promise<{ status: number; body: unknown }> {
  const payload = message as { code?: unknown; deviceToken?: unknown }

  if (op === 'pair') {
    const outcome = vault.pair(payload.code)
    if (!outcome.ok) {
      return { status: 401, body: refusal('invalid-pairing-code', outcome.reason) }
    }
    return {
      status: 200,
      body: { v: PROTOCOL_VERSION, ok: true, deviceToken: outcome.deviceToken },
    }
  }

  const outcome = vault.refresh(payload.deviceToken)
  if (!outcome.ok) {
    return {
      status: 401,
      body: refusal('unauthenticated', 'unknown device token — pair again'),
    }
  }
  return {
    status: 200,
    body: { v: PROTOCOL_VERSION, ok: true, accessToken: outcome.accessToken, expiresAt: outcome.expiresAt },
  }
}

/** Thrown when a request body exceeds {@link MAX_BODY_BYTES}. */
class TooLargeError extends Error {
  constructor() {
    super(`body exceeds ${MAX_BODY_BYTES} bytes`)
    this.name = 'TooLargeError'
  }
}

/**
 * Read a request body, refusing to grow past the ceiling. The limit is enforced
 * while collecting, not after, so an oversized body is never fully buffered.
 */
async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const buffer = chunk as Buffer
    size += buffer.length
    if (size > MAX_BODY_BYTES) throw new TooLargeError()
    chunks.push(buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}
