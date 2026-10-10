/**
 * WebSocket 成帧契约：本网关使用的 RFC 6455 子集，全是纯函数 —— 字节级、
 * 无副作用，因此无需 socket 即可测试。
 *
 * 手写实现：插件只引 Node 内建（dev/plans/M0 §5.1 —— dsh 安装树之外
 * 不允许裸 specifier），所以没有 `ws`；子集恰好是 mux 所需 —— 双向文本、
 * ping/pong 心跳、close —— 无扩展、无二进制、无 deflate。
 *
 * 处理了 RFC 6455 的两处不对称，而非吸收掉：客户端帧是 MASKED 的、必须
 * 去掩码，服务端帧从不掩码；消息可能分片到达，解析器因此是增量的
 * （M2 §3.2/§4.4 step 1）。
 */

import { createHash } from 'node:crypto'

/** 每个 WebSocket accept key 的推导源头（RFC 6455 §1.3）。 */
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

/**
 * 握手请求的 `Sec-WebSocket-Accept` 值。
 *
 * @returns base64 摘要；key 缺失时 `undefined`。
 */
export function acceptKeyOf(headers: Readonly<Record<string, string | string[] | undefined>>): string | undefined {
  const key = headerOf(headers, 'sec-websocket-key')
  if (key === undefined) return undefined
  return createHash('sha1').update(key + WS_GUID).digest('base64')
}

/** 大小写不敏感的单头查找。 */
function headerOf(headers: Readonly<Record<string, string | string[] | undefined>>, name: string): string | undefined {
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() !== name) continue
    return Array.isArray(value) ? value[0] : value
  }
  return undefined
}

/** 校验通过的握手对应的 `101` 应答头。 */
export function handshakeResponse(accept: string): string {
  return [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`,
    '\r\n',
  ].join('\r\n')
}

/** 本网关使用的 RFC 6455 opcode。其余一律关闭连接。 */
const OP_CONTINUATION = 0x0
const OP_TEXT = 0x1
const OP_CLOSE = 0x8
const OP_PING = 0x9
const OP_PONG = 0xa

/**
 * 从客户端字节流中解析出的一帧。控制帧可穿插于文本消息的分片之间；
 * 只有文本（及其 continuation）携带能到达 mux 的载荷。
 */
export interface WsTextFrame {
  kind: 'text'
  /** 一条完整文本消息去掩码后的 UTF-8 载荷。 */
  text: string
}

/** ping —— 以携带同一载荷的 pong 应答。 */
export interface WsPingFrame {
  kind: 'ping'
  payload: Buffer
}

/** pong —— 客户端对我们心跳 ping 的回答。 */
export interface WsPongFrame {
  kind: 'pong'
}

/** close —— 原样回送，然后 socket 关闭。 */
export interface WsCloseFrame {
  kind: 'close'
}

/** 一条完整重组的客户端消息。 */
export type WsFrame = WsTextFrame | WsPingFrame | WsPongFrame | WsCloseFrame

/**
 * 一条 WebSocket 连接客户端侧的增量解析器：socket 送来的是块，不是帧，
 * 未完成的文本分片跨块存放在此。
 */
export class WsFrameParser {
  /** 未完成文本消息目前重组到的部分。 */
  private fragments: Buffer[] = []

  /**
   * 消费字节，完成其中能完成的所有消息。
   *
   * @returns 已完成的帧与已消费的字节数 —— 其余属于未完成的帧，须随下一个
   *   块重新提交。协议违规（保留 opcode、未掩码的客户端帧、超长长度）返回
   *   `error`：调用方据此关闭，因为破坏成帧的对端说的不是这个协议。
   */
  push(chunk: Buffer): { frames: WsFrame[]; consumed: number; error?: string } {
    const frames: WsFrame[] = []
    let offset = 0
    while (offset < chunk.length) {
      const parsed = WsFrameParser.parseOne(chunk, offset)
      if ('error' in parsed) return { frames, consumed: offset, error: parsed.error }
      if (parsed.frame === undefined) break // 此帧还需更多字节
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

  /** 在 `offset` 处解析一帧；无帧且无错即「还需更多字节」。 */
  private static parseOne(
    chunk: Buffer,
    offset: number,
  ): { frame?: (WsFrame | { kind: 'text-fragment'; payload: Buffer; fin: boolean }); consumed: number; error?: string } {
    // 定长头部：2 字节。
    if (chunk.length - offset < 2) return { consumed: offset }
    const b0 = chunk[offset]
    const b1 = chunk[offset + 1]
    const fin = (b0 & 0x80) !== 0
    const opcode = b0 & 0x0f
    const masked = (b1 & 0x80) !== 0
    let length = b1 & 0x7f
    let headerLength = 2

    // 客户端帧必须掩码（RFC 6455 §5.1）—— 不掩码的对端不是符合
    // 浏览器规范的客户端。
    if (!masked) return { consumed: offset, error: 'client frame is not masked' }

    // 扩展长度：126 → 再加 2 字节，127 → 再加 8 字节。
    if (length === 126) {
      if (chunk.length - offset < 4) return { consumed: offset }
      length = chunk.readUInt16BE(offset + 2)
      headerLength = 4
    } else if (length === 127) {
      if (chunk.length - offset < 10) return { consumed: offset }
      const big = chunk.readBigUInt64BE(offset + 2)
      // 超过体量上限的消息不是演示要防的对象，成帧滥用才是。此守卫让
      // BigInt 运算不进常路。
      if (big > BigInt(Number.MAX_SAFE_INTEGER)) return { consumed: offset, error: 'frame too large' }
      length = Number(big)
      headerLength = 10
    }

    const total = headerLength + 4 + length // + 掩码键
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

/** 载荷与 4 字节掩码异或，原地进行（RFC 6455 §5.3）。 */
function unmask(payload: Buffer, maskKey: Buffer): void {
  for (let index = 0; index < payload.length; index += 1) {
    payload[index] ^= maskKey[index % 4]
  }
}

/** 编码一帧未掩码的服务端文本帧（FIN，不分片）。 */
export function encodeTextFrame(text: string): Buffer {
  return encodeFrame(0x1, Buffer.from(text, 'utf8'))
}

/** 编码回应 ping 的 pong（载荷相同，依 RFC 6455 §5.5.3）。 */
export function encodePong(payload: Buffer): Buffer {
  return encodeFrame(0xa, payload)
}

/** 编码心跳用的服务端发起 ping。 */
export function encodePing(): Buffer {
  return encodeFrame(0x9, Buffer.alloc(0))
}

/** 编码干净的 close 帧。 */
export function encodeClose(): Buffer {
  return encodeFrame(0x8, Buffer.alloc(0))
}

function encodeFrame(opcode: number, payload: Buffer): Buffer {
  // 服务端帧从不掩码。长度：<126 内联，<65536 用 16 位，
  // 更大用 64 位（实际不应出现）。
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
