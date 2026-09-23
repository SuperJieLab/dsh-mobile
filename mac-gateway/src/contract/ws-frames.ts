/**
 * The WebSocket framing contract: the RFC 6455 subset this gateway speaks, as pure functions —
 * byte-level and side-effect-free, hence testable without a socket.
 *
 * Hand-rolled: the plugin imports Node builtins only (docs/dev/plans/M0 §5.1 — no bare specifiers
 * outside the dsh installation), so no `ws`; the subset is exactly what the mux needs — text both
 * ways, ping/pong heartbeat, close — no extensions, no binary, no deflate.
 *
 * Two RFC 6455 asymmetries are handled, not absorbed: client frames are MASKED and must be
 * unmasked, server frames never are; and a message may arrive fragmented, so the parser is
 * incremental (docs/dev/plans/M2-realtime-transient.md §3.2/§4.4 step 1).
 */

import { createHash } from 'node:crypto'

/** The GUID every WebSocket accept key is derived from (RFC 6455 §1.3). */
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

/**
 * The `Sec-WebSocket-Accept` value for a handshake request.
 *
 * @returns the base64 digest, or `undefined` when the key is missing.
 */
export function acceptKeyOf(headers: Readonly<Record<string, string | string[] | undefined>>): string | undefined {
  const key = headerOf(headers, 'sec-websocket-key')
  if (key === undefined) return undefined
  return createHash('sha1').update(key + WS_GUID).digest('base64')
}

/** Case-insensitive single header lookup. */
function headerOf(headers: Readonly<Record<string, string | string[] | undefined>>, name: string): string | undefined {
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() !== name) continue
    return Array.isArray(value) ? value[0] : value
  }
  return undefined
}

/** The `101` response headers for a validated handshake. */
export function handshakeResponse(accept: string): string {
  return [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`,
    '\r\n',
  ].join('\r\n')
}

/** RFC 6455 opcodes this gateway uses. Everything else closes the connection. */
const OP_CONTINUATION = 0x0
const OP_TEXT = 0x1
const OP_CLOSE = 0x8
const OP_PING = 0x9
const OP_PONG = 0xa

/**
 * One frame parsed out of the client's byte stream. Control frames may interleave between fragments
 * of a text message; only text (and its continuations) carries payload that reaches the mux.
 */
export interface WsTextFrame {
  kind: 'text'
  /** The unmasked UTF-8 payload of one complete text message. */
  text: string
}

/** A ping — answered with a pong carrying the same payload. */
export interface WsPingFrame {
  kind: 'ping'
  payload: Buffer
}

/** A pong — the client's answer to our heartbeat ping. */
export interface WsPongFrame {
  kind: 'pong'
}

/** A close — echoed back, then the socket dies. */
export interface WsCloseFrame {
  kind: 'close'
}

/** One fully reassembled client message. */
export type WsFrame = WsTextFrame | WsPingFrame | WsPongFrame | WsCloseFrame

/**
 * An incremental parser for the client side of one WebSocket connection: the socket delivers
 * chunks, not frames, and unfinished text fragments live here across them.
 */
export class WsFrameParser {
  /** Assembled so far of an unfinished text message. */
  private fragments: Buffer[] = []

  /**
   * Consume bytes, completing as many messages as they hold.
   *
   * @returns the completed frames and the bytes consumed — everything past that belongs to an
   *   unfinished frame and must be re-presented with the next chunk. A protocol violation (reserved
   *   opcode, unmasked client frame, oversized length) returns `error`: the caller closes, because
   *   a peer that breaks framing is not speaking this protocol.
   */
  push(chunk: Buffer): { frames: WsFrame[]; consumed: number; error?: string } {
    const frames: WsFrame[] = []
    let offset = 0
    while (offset < chunk.length) {
      const parsed = WsFrameParser.parseOne(chunk, offset)
      if ('error' in parsed) return { frames, consumed: offset, error: parsed.error }
      if (parsed.frame === undefined) break // need more bytes for this frame
      offset += parsed.consumed
      const frame = parsed.frame
      if (frame.kind === 'text-fragment') {
        this.fragments.push(frame.payload)
        if (frame.fin) {
          frames.push({ kind: 'text', text: Buffer.concat(this.fragments).toString('utf8') })
          this.fragments = []
        }
      } else {
        frames.push(frame)
      }
    }
    return { frames, consumed: offset }
  }

  /** Parse one frame at `offset`; no frame and no error means "need more bytes". */
  private static parseOne(
    chunk: Buffer,
    offset: number,
  ): { frame?: (WsFrame | { kind: 'text-fragment'; payload: Buffer; fin: boolean }); consumed: number; error?: string } {
    // Fixed header: 2 bytes.
    if (chunk.length - offset < 2) return { consumed: offset }
    const b0 = chunk[offset]
    const b1 = chunk[offset + 1]
    const fin = (b0 & 0x80) !== 0
    const opcode = b0 & 0x0f
    const masked = (b1 & 0x80) !== 0
    let length = b1 & 0x7f
    let headerLength = 2

    // Client frames MUST be masked (RFC 6455 §5.1) — a peer that does not mask
    // is not a browser-conformant client.
    if (!masked) return { consumed: offset, error: 'client frame is not masked' }

    // Extended lengths: 126 → 2 more bytes, 127 → 8 more.
    if (length === 126) {
      if (chunk.length - offset < 4) return { consumed: offset }
      length = chunk.readUInt16BE(offset + 2)
      headerLength = 4
    } else if (length === 127) {
      if (chunk.length - offset < 10) return { consumed: offset }
      const big = chunk.readBigUInt64BE(offset + 2)
      // A message larger than the body ceiling is not a demo concern; framing
      // abuse is. The guard keeps BigInt arithmetic out of the common path.
      if (big > BigInt(Number.MAX_SAFE_INTEGER)) return { consumed: offset, error: 'frame too large' }
      length = Number(big)
      headerLength = 10
    }

    const total = headerLength + 4 + length // + mask key
    if (chunk.length - offset < total) return { consumed: offset }

    const maskKey = chunk.subarray(offset + headerLength, offset + headerLength + 4)
    const payload = Buffer.from(chunk.subarray(offset + headerLength + 4, offset + total))
    unmask(payload, maskKey)

    if (opcode === OP_TEXT || opcode === OP_CONTINUATION) {
      return { consumed: total, frame: { kind: 'text-fragment', payload, fin } }
    }
    if (opcode === OP_PING) return { consumed: total, frame: { kind: 'ping', payload } }
    if (opcode === OP_PONG) return { consumed: total, frame: { kind: 'pong' } }
    if (opcode === OP_CLOSE) return { consumed: total, frame: { kind: 'close' } }
    return { consumed: offset, error: `reserved opcode ${opcode}` }
  }
}

/** XOR the payload with its 4-byte mask, in place (RFC 6455 §5.3). */
function unmask(payload: Buffer, maskKey: Buffer): void {
  for (let index = 0; index < payload.length; index += 1) {
    payload[index] ^= maskKey[index % 4]
  }
}

/** Encode one unmasked server text frame (FIN, no fragmentation). */
export function encodeTextFrame(text: string): Buffer {
  return encodeFrame(0x1, Buffer.from(text, 'utf8'))
}

/** Encode a pong answering a ping (same payload, per RFC 6455 §5.5.3). */
export function encodePong(payload: Buffer): Buffer {
  return encodeFrame(0xa, payload)
}

/** Encode a server-initiated ping for the heartbeat. */
export function encodePing(): Buffer {
  return encodeFrame(0x9, Buffer.alloc(0))
}

/** Encode a clean close frame. */
export function encodeClose(): Buffer {
  return encodeFrame(0x8, Buffer.alloc(0))
}

function encodeFrame(opcode: number, payload: Buffer): Buffer {
  // Server frames are never masked. Lengths: inline <126, 16-bit <65536,
  // 64-bit beyond (not expected in practice).
  if (payload.length < 126) {
    const head = Buffer.from([0x80 | opcode, payload.length])
    return Buffer.concat([head, payload])
  }
  if (payload.length < 65_536) {
    const head = Buffer.alloc(4)
    head[0] = 0x80 | opcode
    head[1] = 126
    head.writeUInt16BE(payload.length, 2)
    return Buffer.concat([head, payload])
  }
  const head = Buffer.alloc(10)
  head[0] = 0x80 | opcode
  head[1] = 127
  head.writeBigUInt64BE(BigInt(payload.length), 2)
  return Buffer.concat([head, payload])
}
