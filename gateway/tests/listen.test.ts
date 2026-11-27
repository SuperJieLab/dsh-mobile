/**
 * 绑定的重试。
 *
 * 守的是真机上的那一次：「dsh 起来了，Tailscale 的地址还没挂上」，`listen` 报
 * `EADDRNOTAVAIL`，而 Node 不会自己再试 —— 进程在跑、端口没人听，手机侧看到的是
 * 一次 SOCKS 建连失败（`-1000 bad URL`），网关侧一条请求记录都没有。
 *
 * 用替身服务器与手动定时器：这条判据要的是「第几次之后成功」「排了多久之后」，
 * 不是真等十秒。
 *
 * Run: node --test tests/listen.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import type { Server } from 'node:net'

import { bindWithRetry } from '../src/listen.ts'

/** 每次 `listen` 取一个结果：错误码字符串表示失败，`null` 表示成功。 */
class FakeServer extends EventEmitter {
  listening = false
  readonly calls: Array<{ port: number; host: string }> = []
  private readonly outcomes: Array<string | null>

  constructor(outcomes: Array<string | null>) {
    super()
    this.outcomes = [...outcomes]
  }

  listen(port: number, host: string): this {
    this.calls.push({ port, host })
    const outcome = this.outcomes.length > 0 ? this.outcomes.shift()! : null
    if (outcome === null) {
      this.listening = true
      this.emit('listening')
    } else {
      const error = Object.assign(new Error(outcome), { code: outcome })
      this.emit('error', error)
    }
    return this
  }

  close(): this {
    this.listening = false
    return this
  }
}

/** 手动定时器：跑不跑、什么时候跑由用例决定。 */
class Timers {
  private queue: Array<{ run: () => void; delayMs: number; cancelled: boolean }> = []

  schedule = (run: () => void, delayMs: number): number => {
    this.queue.push({ run, delayMs, cancelled: false })
    return this.queue.length - 1
  }

  cancel = (handle: unknown): void => {
    const entry = this.queue[handle as number]
    if (entry) entry.cancelled = true
  }

  get delays(): number[] {
    return this.queue.map(entry => entry.delayMs)
  }

  runNext(): boolean {
    const entry = this.queue.shift()
    if (!entry || entry.cancelled) return false
    entry.run()
    return true
  }
}

test('a missing address is retried with backoff until it appears', () => {
  const server = new FakeServer(['EADDRNOTAVAIL', 'EADDRNOTAVAIL', null])
  const timers = new Timers()
  const retries: Array<{ attempts: number; delayMs: number }> = []
  const listened: number[] = []

  bindWithRetry(server as unknown as Server, {
    port: 3081,
    host: '100.64.0.1',
    schedule: timers.schedule,
    cancel: timers.cancel,
    onRetry: (_error, attempts, delayMs) => retries.push({ attempts, delayMs }),
    onListening: attempts => listened.push(attempts),
  })

  assert.equal(server.calls.length, 1, '第一次是立刻试的')
  assert.deepEqual(server.calls[0], { port: 3081, host: '100.64.0.1' })
  assert.deepEqual(retries, [{ attempts: 1, delayMs: 500 }], '失败一次就排一次重试')

  timers.runNext()
  assert.equal(server.calls.length, 2)
  assert.deepEqual(retries.at(-1), { attempts: 2, delayMs: 1000 }, '退避翻倍')

  timers.runNext()
  assert.equal(server.calls.length, 3)
  assert.deepEqual(listened, [3], '第三次才成，报出来的次数是 3')
})

test('a non-retryable failure gives up immediately instead of looping', () => {
  const server = new FakeServer(['EACCES'])
  const timers = new Timers()
  const given: Array<{ code: string | undefined; attempts: number }> = []

  bindWithRetry(server as unknown as Server, {
    port: 80,
    host: '0.0.0.0',
    schedule: timers.schedule,
    cancel: timers.cancel,
    onGiveUp: (error, attempts) => given.push({ code: error.code, attempts }),
  })

  assert.deepEqual(given, [{ code: 'EACCES', attempts: 1 }])
  assert.equal(timers.delays.length, 0, '不排下一次：权限问题再试也不会成')
})

test('the retry stops when the plugin unloads', () => {
  const server = new FakeServer(['EADDRNOTAVAIL', 'EADDRNOTAVAIL'])
  const timers = new Timers()
  let listened = 0

  const stop = bindWithRetry(server as unknown as Server, {
    port: 3081,
    host: '100.64.0.1',
    schedule: timers.schedule,
    cancel: timers.cancel,
    onListening: () => { listened += 1 },
  })

  assert.equal(server.calls.length, 1)
  stop()
  assert.equal(timers.runNext(), false, '卸载之后那一次不该跑')
  assert.equal(server.calls.length, 1)
  assert.equal(listened, 0)
})

test('errors after the listener is up are not treated as a bind failure', () => {
  const server = new FakeServer([null])
  const timers = new Timers()
  const after: string[] = []
  const retries: number[] = []

  bindWithRetry(server as unknown as Server, {
    port: 3081,
    host: '100.64.0.1',
    schedule: timers.schedule,
    cancel: timers.cancel,
    onFailureAfterListening: error => after.push(String(error)),
    onRetry: (_error, attempts) => retries.push(attempts),
  })

  server.emit('error', Object.assign(new Error('ECONNRESET'), { code: 'ECONNRESET' }))

  assert.equal(after.length, 1, '运行期错误交出去')
  assert.equal(timers.delays.length, 0, '不重来 —— 重开会把正在服务的端口关掉')
  assert.deepEqual(retries, [])
})
