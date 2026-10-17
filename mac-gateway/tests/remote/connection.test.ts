/**
 * 一条连接的测试：握手拒绝、心跳的两条规则、以及一次连接是怎么结束的。
 *
 * 这些用例的共同点：它们都在问「这一条 socket 的死活」，而不是流的内容。
 * 握手拒绝之后没有任何流存在；心跳掐的是这条连接；`endReasonOf` 判的是它的死因。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer, request as httpRequest, type Server } from 'node:http'
import { once } from 'node:events'
import { connect as tcpConnect } from 'node:net'
import { attachStreamHandler } from '../../src/remote/server.ts'
import { endReasonOf, startHeartbeat, STREAM_PATH, type HeartbeatSocket } from '../../src/remote/connection.ts'
import { connect, event, fakeSource, snapshotFrame } from './harness.ts'

test('an unknown upgrade path is declined without speaking WebSocket', { timeout: 10_000 }, async () => {
  const source = fakeSource([])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const address = server.address()
    assert.ok(address !== null && typeof address === 'object')

    // fetch refuses to send `Connection: Upgrade`; an upgrade probe is a raw
    // HTTP request, which is also what a real client's handshake looks like.
    const status = await new Promise<number>((resolve, reject) => {
      const request = httpRequest(
        { host: '127.0.0.1', port: address.port, path: '/other',
          headers: { connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==', 'sec-websocket-version': '13' } },
        response => { resolve(response.statusCode ?? 0); response.resume() },
      )
      request.on('error', reject)
      request.end()
    })
    assert.equal(status, 404)
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

/** A socket the heartbeat alone reads — its write queue can be set from the test. */
function fakeSocket(writableLength: number) {
  const socket = {
    writableLength,
    destroyed: false,
    writes: 0,
    destroy(): void { socket.destroyed = true },
    write(): void { socket.writes += 1 },
  }
  return socket
}

test('heartbeat: a socket still draining a big frame is not judged dead', { timeout: 5_000 }, async () => {
  // 真机现场（2026-10-14）：1.25 MB 的打开帧在慢链路上要 ~10 秒才传完，而我们自己的 ping
  // 与那一大帧走同一条 TCP、排在它**后面** —— 客户端此刻收不到 ping，收不到就不会回 pong。
  // 把这段算成死亡，连接就会在帧传到一半时被自己掐断（真机表现：客户端每代 2.02 秒一转，
  // 而网关侧连 upgrade 都还没完成）。这里用 10ms 节拍把同一条路径压到一个测试里。
  const sleep = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms))
  const socket = fakeSocket(64 * 1024)
  const beat = startHeartbeat(socket, { intervalMs: 10, missedPongLimit: 1 })
  try {
    // ① 写还在排队：不计数（不修则第一拍就判死），也不把 ping 排到队尾去
    await sleep(60)
    assert.equal(socket.destroyed, false, 'while a big frame is draining, a missing pong proves nothing')
    assert.equal(socket.writes, 0, 'no ping is queued behind the frame it would be stuck behind')

    // ② 排空了、pong 按时回：活着
    socket.writableLength = 0
    const pongs = setInterval(() => beat.heardFrame(), 3)
    await sleep(60)
    assert.equal(socket.destroyed, false, 'a peer that answers pings is alive')
    clearInterval(pongs)

    // ③ 排空了、pong 不再回：判死 —— 半开连接仍然会被发现
    await sleep(60)
    assert.equal(socket.destroyed, true, 'once drained, silence is still death')
  } finally {
    beat.stop()
  }
})

test('endReasonOf: the four ways a connection can end are told apart, strongest evidence first', () => {
  // 网关侧只看得到「socket 关了」，但四档的后续动作完全不同（改心跳规则 / 什么都不做 /
  // 查传输 / 读错误原文）。判据取真实收到的信号，不靠推断。
  assert.equal(endReasonOf({ killed: false, cleanClose: false, errored: false }), 'the link dropped',
    'no signal at all means it broke in the middle, without even a goodbye')
  assert.equal(endReasonOf({ killed: false, cleanClose: true, errored: false }), 'the peer closed it cleanly')
  assert.equal(endReasonOf({ killed: true, cleanClose: false, errored: false }), 'we closed it (no pong)')
  assert.equal(endReasonOf({ killed: false, cleanClose: false, errored: true }), 'the socket errored')
  assert.equal(endReasonOf({ killed: true, cleanClose: true, errored: true }), 'the socket errored',
    'an error outranks everything: it names the cause most precisely')
})

test('heartbeat: a killed connection can name its killer, an untouched one says otherwise', { timeout: 5_000 }, async () => {
  // 「连接结束」那行必须说出是谁关的。Mac 侧此前对断连一行不记，于是真机上「客户端每 35–60 秒
  // 断一次」在网关侧完全看不出来（2026-10-15）—— 两端只有一端有日志，问题就永远定不了性。
  const sleep = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms))

  const alive = fakeSocket(0)
  const beat = startHeartbeat(alive, { intervalMs: 10, missedPongLimit: 1 })
  try {
    assert.equal(beat.killed, false, 'nothing has been closed yet')
    const pongs = setInterval(() => beat.heardFrame(), 3)
    await sleep(60)
    clearInterval(pongs)
    assert.equal(alive.destroyed, false)
    assert.equal(beat.killed, false, 'a connection the peer keeps alive was not closed by us')
  } finally {
    beat.stop()
  }

  const doomed = fakeSocket(0)
  const killer = startHeartbeat(doomed, { intervalMs: 10, missedPongLimit: 1 })
  try {
    await sleep(60)
    assert.equal(doomed.destroyed, true)
    assert.equal(killer.killed, true, 'the heartbeat must be able to name itself as the closer')
  } finally {
    killer.stop()
  }
})

test('heartbeat: a peer that keeps sending frames is alive even though it never answers a ping', { timeout: 10_000 }, async () => {
  // 真机现场（2026-10-14 第三次复验）：客户端每代连接恰好活 6 秒就被自己判死，而网关侧那次
  // `heartbeat: no pong … closing socket` 只是余波。两端同族 —— **我们的 pong 可能正排在一大帧
  // 后面**（1.25 MB 的打开帧 + 中继链路，那一整段时间里链路上什么都过不来），于是客户端回不了
  // pong 不是因为它死了，而是因为我们还没把它要答的那一帧发完。
  //
  // 所以判据不能只认 pong：客户端每 2 秒一次的 ping 走的是**未被堵住**的方向（客户端 → 网关），
  // 它同样证明客户端在看。这条用一只**手写客户端**驱动（Node 内置的那个会自动回 pong，
  // 那门自动应答恰好会遮住要测的东西），心跳节拍压到 20ms（3 拍即判死）。
  const source = fakeSource([snapshotFrame([event(0)], 1)])
  const server = createServer()
  attachStreamHandler(server, source, { authenticate: () => true }, {
    heartbeat: { intervalMs: 20, missedPongLimit: 1 },
  })
  server.listen(0)
  let client: { send: (opcode: number, payload: Buffer) => void; gone: () => boolean; upgraded: Promise<void>; close: () => void } | undefined
  let chatter: NodeJS.Timeout | undefined
  try {
    await once(server, 'listening')
    client = await silentClient(server)

    // ① **从第一刻就送**、从不答 pong：活着。晚一步就测不着本条要测的东西 —— 心跳的容错只有两拍
    //（`missedPongLimit: 1` ⇒ 第 2 拍即判死，40ms），慢慢起手的客户端会在第一记 ping 之前就被关掉。
    chatter = setInterval(() => client?.send(OP_PING, Buffer.alloc(0)), 5)
    await client.upgraded // 服务端确实在处理这条连接（否则这条用例会因为「谁都没说话」而假绿）
    await new Promise(resolve => setTimeout(resolve, 200))
    assert.equal(client.gone(), false, 'a peer that keeps talking is not dead — its pong may be queued behind our own frame')

    // ② 一旦真的安静下来：仍然判死 —— 这条规则没有把心跳变成空转
    clearInterval(chatter)
    chatter = undefined
    await new Promise(resolve => setTimeout(resolve, 200))
    assert.equal(client.gone(), true, 'once it goes quiet, silence is still death')
  } finally {
    if (chatter !== undefined) clearInterval(chatter)
    // 裸 socket 必须自己关：留着它，node:test 等不到事件循环排空（整条测试进程会被拖住）。
    client?.close()
    server.closeAllConnections()
    server.close()
  }
})

const OP_PING = 0x9

/**
 * 一只**自己说话**的 WebSocket 客户端：手写握手、手写成帧，且除测试明确要求外**什么都不答**。
 *
 * 为什么不直接用内置的 `WebSocket`：它会自动应答每一记 ping（RFC 6455 §5.5.3）—— 那恰好遮住
 * 本条要证的东西（「对端没回 pong」到底能不能推出「对端死了」）。只有一只肯闭嘴的客户端，
 * 才能把「一直在送帧」与「pong 答不上来」这两件事分开。
 */
async function silentClient(server: Server): Promise<{
  send: (opcode: number, payload: Buffer) => void
  gone: () => boolean
  upgraded: Promise<void>
  close: () => void
}> {
  const address = server.address()
  assert.ok(address !== null && typeof address === 'object')
  const socket = tcpConnect(address.port, '127.0.0.1')
  let gone = false
  let upgraded: () => void = () => {}
  const upgradedPromise = new Promise<void>(resolve => { upgraded = resolve })
  socket.on('close', () => { gone = true })
  socket.on('data', () => upgraded()) // 排掉 101 与随后的 opening，本条不读帧；有数据即「服务端开口了」
  await once(socket, 'connect')
  socket.write([
    `GET ${STREAM_PATH} HTTP/1.1`,
    `Host: 127.0.0.1:${address.port}`,
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==', // '0123456789abcdef' 的 base64
    'Sec-WebSocket-Version: 13',
    '\r\n',
  ].join('\r\n'))
  return {
    send: (opcode, payload) => socket.write(maskedClientFrame(opcode, payload)),
    gone: () => gone || socket.destroyed,
    upgraded: upgradedPromise,
    close: () => socket.destroy(),
  }
}

/** 编码一帧带掩码的客户端帧 —— 解析器强制要求（RFC 6455 §5.1）。 */
function maskedClientFrame(opcode: number, payload: Buffer): Buffer {
  const key = Buffer.from([0x21, 0x43, 0x65, 0x87])
  const body = Buffer.from(payload)
  for (let index = 0; index < body.length; index += 1) body[index] ^= key[index % 4]
  assert.ok(body.length < 126, 'test frames stay short')
  return Buffer.concat([Buffer.from([0x80 | opcode, 0x80 | body.length]), key, body])
}

test('a connection that breaks framing does not take the listener down with it', { timeout: 10_000 }, async () => {
  // 成帧破坏的处置是 `socket.destroy()` —— 只这一条。若它退化成「关掉服务端」或
  // 「抛到监听器」，一个坏客户端就能让所有人的流断掉。这条用一个真坏的字节流
  // 撞它，然后确认服务端仍在接受新连接。
  const server = createServer()
  attachStreamHandler(server, fakeSource([]), { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const address = server.address()
    assert.ok(address !== null && typeof address === 'object')

    // ① 一条说坏话的连接：握手之后送一段既非合法帧、也非合法文本的字节。
    const raw = tcpConnect(address.port, '127.0.0.1')
    await once(raw, 'connect')
    raw.write(
      `GET ${STREAM_PATH} HTTP/1.1\r\nHost: 127.0.0.1\r\n`
      + 'Connection: Upgrade\r\nUpgrade: websocket\r\n'
      + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n',
    )
    await once(raw, 'data') // 101
    // 0xFF 不是任何一个合法 opcode —— 解析器会拒绝这整条连接。
    raw.write(Buffer.from([0xff, 0x81, 0x80, 0x00, 0x00, 0x00, 0x00]))
    await new Promise(resolve => setTimeout(resolve, 100))
    raw.destroy()

    // ② 服务端仍然活着：新连接照常升级、照常拿到帧。
    const healthy = await connect(server)
    assert.ok(healthy.readyState === WebSocket.OPEN, 'the listener still accepts new connections')
    healthy.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  } finally {
    server.closeAllConnections()
    server.close()
  }
})
