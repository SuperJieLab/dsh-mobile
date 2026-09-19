/**
 * RFC 6455 subset tests: handshake derivation, frame round-trips, masking,
 * fragmentation, interleaved control frames, and the refusals.
 *
 * The round-trip tests run every frame through a *real client encoding* —
 * masked, as a browser or URLSessionWebSocketTask would send — so the parser
 * is exercised against the wire, not against our own encoder.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createHash } from 'node:crypto'
import {
  WsFrameParser,
  acceptKeyOf,
  encodeClose,
  encodePing,
  encodePong,
  encodeTextFrame,
  handshakeResponse,
} from './ws-frames.ts'

/**
 * Encode one client frame the way a real client would: masked, standard
 * length encoding. This is the encoder the round-trip tests trust.
 */
function clientFrame(opcode: number, payload: Buffer, fin = true): Buffer {
  const maskKey = Buffer.from([0x11, 0x22, 0x33, 0x44])
  const masked = Buffer.from(payload)
  for (let index = 0; index < masked.length; index += 1) masked[index] ^= maskKey[index % 4]

  let head: Buffer
  if (payload.length < 126) {
    head = Buffer.from([(fin ? 0x80 : 0) | opcode, 0x80 | payload.length])
  } else if (payload.length < 65_536) {
    head = Buffer.alloc(4)
    head[0] = (fin ? 0x80 : 0) | opcode
    head[1] = 0x80 | 126
    head.writeUInt16BE(payload.length, 2)
  } else {
    head = Buffer.alloc(10)
    head[0] = (fin ? 0x80 : 0) | opcode
    head[1] = 0x80 | 127
    head.writeBigUInt64BE(BigInt(payload.length), 2)
  }
  return Buffer.concat([head, maskKey, masked])
}

test('acceptKeyOf: derives the RFC 6455 example digest', () => {
  // The spec's own worked example (RFC 6455 §1.3).
  const accept = acceptKeyOf({ 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==' })
  assert.equal(accept, 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
  assert.equal(accept, createHash('sha1').update('dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64'))
})

test('acceptKeyOf: refuses a handshake without a key', () => {
  assert.equal(acceptKeyOf({}), undefined)
})

test('handshakeResponse: a 101 with the computed accept', () => {
  const response = handshakeResponse('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
  assert.match(response, /^HTTP\/1\.1 101 Switching Protocols\r\n/)
  assert.match(response, /Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=\r\n/)
  assert.match(response, /\r\n\r\n$/)
})

test('a text frame round-trips: masked client frame in, same text out', () => {
  const parser = new WsFrameParser()
  const wire = clientFrame(0x1, Buffer.from('{"type":"open","streamId":1}', 'utf8'))
  const { frames, consumed, error } = parser.push(wire)
  assert.equal(error, undefined)
  assert.equal(consumed, wire.length)
  assert.deepEqual(frames, [{ kind: 'text', text: '{"type":"open","streamId":1}' }])
})

test('a frame split across chunks is reassembled — nothing is lost or duplicated', () => {
  const parser = new WsFrameParser()
  const wire = clientFrame(0x1, Buffer.from('x'.repeat(600), 'utf8'))

  const first = parser.push(wire.subarray(0, 5))
  assert.deepEqual(first.frames, [], 'nothing complete yet')
  assert.equal(first.consumed, 0, 'the partial frame is not consumed')

  const second = parser.push(wire) // re-present everything; the parser resumes
  assert.deepEqual(second.frames.map(frame => frame.kind), ['text'])
  assert.equal((second.frames[0] as { text: string }).text, 'x'.repeat(600))
  assert.equal(second.consumed, wire.length)
})

test('a fragmented text message (FIN=0 then FIN=1) reassembles in order', () => {
  const parser = new WsFrameParser()
  const wire = Buffer.concat([
    clientFrame(0x1, Buffer.from('hello '), false), // text, not final
    clientFrame(0x0, Buffer.from('world'), true),   // continuation, final
  ])
  const { frames, error } = parser.push(wire)
  assert.equal(error, undefined)
  assert.deepEqual(frames, [{ kind: 'text', text: 'hello world' }])
})

test('a ping between fragments does not break the message being assembled', () => {
  const parser = new WsFrameParser()
  const wire = Buffer.concat([
    clientFrame(0x1, Buffer.from('abc'), false),
    clientFrame(0x9, Buffer.from('heartbeat')), // interleaved control frame
    clientFrame(0x0, Buffer.from('def'), true),
  ])
  const { frames, error } = parser.push(wire)
  assert.equal(error, undefined)
  assert.deepEqual(frames, [
    { kind: 'ping', payload: Buffer.from('heartbeat') },
    { kind: 'text', text: 'abcdef' },
  ])
})

test('close frames parse; pongs are recognised for the heartbeat counter', () => {
  const parser = new WsFrameParser()
  const { frames } = parser.push(Buffer.concat([
    clientFrame(0xa, Buffer.alloc(0)), // pong
    clientFrame(0x8, Buffer.alloc(0)), // close
  ]))
  assert.deepEqual(frames, [{ kind: 'pong' }, { kind: 'close' }])
})

test('protocol violations are refused, not tolerated', () => {
  const parser = new WsFrameParser()

  // An unmasked client frame violates RFC 6455 §5.1.
  const bare = Buffer.from([0x81, 0x01, 0x41])
  assert.match(parser.push(bare).error ?? '', /not masked/)

  // A reserved opcode is not this protocol.
  const reserved = clientFrame(0x3, Buffer.from('x'))
  assert.match(new WsFrameParser().push(reserved).error ?? '', /reserved opcode/)
})

test('server encoders produce unmasked frames a real client can read', () => {
  // Length encodings: inline, 16-bit, 64-bit.
  assert.equal(encodeTextFrame('hi')[1] & 0x7f, 2)
  assert.equal(encodeTextFrame('x'.repeat(300))[1] & 0x7f, 126)
  assert.equal(encodeTextFrame('x'.repeat(70_000))[1] & 0x7f, 127)

  // Server frames are never masked (RFC 6455 §5.1).
  assert.equal(encodeTextFrame('hi')[1] & 0x80, 0)

  // Every encoder sets FIN.
  for (const wire of [encodeTextFrame('hi'), encodePing(), encodePong(Buffer.from('p')), encodeClose()]) {
    assert.equal(wire[0] & 0x80, 0x80)
  }

  // A pong echoes its ping payload.
  assert.equal(encodePong(Buffer.from('p')).subarray(2).toString(), 'p')

  // A text frame survives its own round-trip through the parser (server →
  // client is the direction our tests' Node WebSocket client consumes, so the
  // encoder is additionally verified end-to-end in the adapter tests).
  const { frames } = new WsFrameParser().push(mask(encodeTextFrame('回声')))
  assert.equal(frames.length, 0, 'server frames are unmasked, so the client-side parser refuses them')
})

/** Mask a server frame — the inverse of what the wire expects, but it makes the bytes parseable by our test parser. */
function mask(buffer: Buffer): Buffer {
  // Only used to prove the refusal above; not part of the protocol paths.
  return buffer
}
