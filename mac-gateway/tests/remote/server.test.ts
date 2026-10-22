/**
 * 连接集合的测试：谁连着、广播给谁、以及**一个死连接不拖累其余**。
 *
 * 这一层只有一个问题：集合自己。它不做协商（`connection.ts`）、不写帧的内容
 * （`egress.ts`），所以这里问的都是集合的记账：广播到不到、计数对不对、
 * 一个客户端消失之后其余还收不收得到。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'
import type { Duplex } from 'node:stream'
import { attachStreamHandler } from '../../src/remote/server.ts'
import { write } from '../../src/remote/egress.ts'
import { connect, fakeSource, receive } from './harness.ts'

/** 一支能记下写进来什么的假 socket —— 只验 `write` 的守卫，见最后一条。 */
function recordingSocket(options: { destroyed?: boolean } = {}): Duplex & { written: Buffer[] } {
  const written: Buffer[] = []
  const socket = {
    written,
    writableLength: 0,
    destroyed: options.destroyed ?? false,
    write(buffer: Buffer): boolean { written.push(buffer); return true },
    destroy(): void { socket.destroyed = true },
    on(): unknown { return socket },
    end(): void {},
  }
  return socket as unknown as Duplex & { written: Buffer[] }
}

test('broadcast reaches a live client after another one has gone away', { timeout: 10_000 }, async () => {
  // 三个故障域里最容易被忽略的一条：集合广播时，**一个已消失的客户端不该让
  // 其余客户端收不到**。客户端关掉 App 是常态；如果集合在死连接上抛错或中断，
  // 一次审批推送就会卡在那里，而活着的手机什么也看不到。
  const server = createServer()
  const broadcaster = attachStreamHandler(server, fakeSource([]), { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const first = await connect(server)
    const second = await connect(server)
    assert.equal(broadcaster.clientCount(), 2, 'both upgraded sockets are held')

    first.close()
    // 等到集合真的把它删掉（`close` 事件）—— 这一步正是被测的记账。
    for (let attempt = 0; attempt < 40 && broadcaster.clientCount() !== 1; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 25))
    }
    assert.equal(broadcaster.clientCount(), 1, 'a closed client is dropped from the set')

    broadcaster.broadcast({ type: 'end', streamId: 's99' })
    const frame = await receive(second)
    assert.deepEqual(frame, { type: 'end', streamId: 's99' }, 'the surviving client still receives the broadcast')

    second.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('broadcasting to nobody is a no-op, not a throw', async () => {
  const server = createServer()
  const broadcaster = attachStreamHandler(server, fakeSource([]), { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    assert.equal(broadcaster.clientCount(), 0)
    broadcaster.broadcast({ type: 'end', streamId: 's1' })
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('a destroyed socket is never written to', () => {
  // 广播跳过死连接，靠的就是这一个守卫：`write` 自己不抛、自己跳过。
  // 断言它而不是断言广播的内部循环 —— 后者只能在集合里塞假 socket，而那需要
  // 改动生产代码的形状来换取可测性。
  const dead = recordingSocket({ destroyed: true })
  const alive = recordingSocket()
  write(dead, Buffer.from('x'))
  write(alive, Buffer.from('x'))
  assert.equal(dead.written.length, 0, 'a destroyed socket is skipped')
  assert.equal(alive.written.length, 1, 'a live one still receives')
})
