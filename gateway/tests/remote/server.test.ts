/**
 * 连接集合的测试：谁连着、以及一个客户端消失之后计数对不对。
 *
 * 这一层只有一个问题：集合自己。它不做协商（`connection.ts`）、不写字节
 * （`egress.ts`），所以这里问的都是集合的记账。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { once } from 'node:events'
import type { Duplex } from 'node:stream'
import { attachStreamHandler } from '../../src/remote/server.ts'
import { write } from '../../src/remote/egress.ts'
import { connect, fakeSource } from './harness.ts'

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

test('a closed client is dropped from the set, the survivor stays counted', { timeout: 10_000 }, async () => {
  // 三个故障域里最容易被忽略的一条：**一个已消失的客户端不该让其余的记账错位**。
  // 客户端关掉 App 是常态；计数多了，资源采样就在给一个不存在的连接记账。
  const server = createServer()
  const handler = attachStreamHandler(server, fakeSource([]), { authenticate: () => true })
  server.listen(0)
  try {
    await once(server, 'listening')
    const first = await connect(server)
    const second = await connect(server)
    assert.equal(handler.clientCount(), 2, 'both upgraded sockets are held')

    first.close()
    // 等到集合真的把它删掉（`close` 事件）—— 这一步正是被测的记账。
    for (let attempt = 0; attempt < 40 && handler.clientCount() !== 1; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 25))
    }
    assert.equal(handler.clientCount(), 1, 'a closed client is dropped from the set')

    second.close()
  } finally {
    server.closeAllConnections()
    server.close()
  }
})

test('a destroyed socket is never written to', () => {
  // 写出前的死连接守卫在 `egress.ts`：`write` 自己不抛、自己跳过。
  // 断言它而不是断言某个循环 —— 后者只能在集合里塞假 socket，而那需要改动生产
  // 代码的形状来换取可测性。
  const dead = recordingSocket({ destroyed: true })
  const alive = recordingSocket()
  write(dead, Buffer.from('x'))
  write(alive, Buffer.from('x'))
  assert.equal(dead.written.length, 0, 'a destroyed socket is skipped')
  assert.equal(alive.written.length, 1, 'a live one still receives')
})
