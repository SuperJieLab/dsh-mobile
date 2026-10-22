/**
 * 上游假件的共用处 —— `$events` 流与「等到某件事发生」。
 *
 * 这里替代的是**上游的 `$events` 身份**（网络与宿主之外）；流、socket、成帧都是真的。
 */

import assert from 'node:assert/strict'

import type { RemoteEventStreamLike } from '../../src/upstream/remote-events.ts'
import type { UpstreamWireFrame } from '../../src/ports/events.ts'

/**
 * 一份由测试驱动的 `$events` 源；每一代都有自己的 clientId。
 *
 * `failFirstOpen` 让第一次开流直接抛：那是「宿主拒了我们」这条路径，退避之后下一代
 * 正常服务。
 */
export function fakeEventStream(options: { failFirstOpen?: boolean } = {}) {
  const channels: ((frame: UpstreamWireFrame) => void)[] = []
  const breakers: (() => void)[] = []
  // 构造 `started` 的 executor 是同步跑的，所以任何调用方拿到 `feed` 之前它已经赋值 ——
  // 下面三处 `announce()` 没有「还没赋值」的那一态。
  let announce!: () => void
  const started = new Promise<void>((resolve) => { announce = resolve })
  let opened = 0

  const source: RemoteEventStreamLike = {
    async *openWireStream(endpoint, _payload, signal) {
      assert.equal(endpoint, '$events', 'the identity opens the forwarded-event stream and nothing else')
      opened += 1
      if (options.failFirstOpen === true && opened === 1) {
        // 叫醒等待方再抛：否则这个用例会挂到超时，看不出「失败」与「卡住」的区别。
        announce()
        throw new Error('stream broke')
      }
      const queue: UpstreamWireFrame[] = []
      // 推送通道要在第一个 yield 之前登记：夹在 body 起点与 ready 之间的那一帧不能丢。
      channels.push((frame) => queue.push(frame))
      let broken = false
      breakers.push(() => { broken = true })
      announce()
      yield { type: 'ready', clientId: `client-${opened}` }
      while (!signal.aborted && !broken) {
        while (queue.length > 0) yield queue.shift()!
        await new Promise<void>((resolve) => setTimeout(resolve, 5))
      }
    },
  }

  return {
    source,
    started,
    get opened() { return opened },
    push(frame: UpstreamWireFrame): void { channels.at(-1)?.(frame) },
    /** 结束当前这一代（正常收尾，不是抛错）。 */
    end(): void { breakers.at(-1)?.() },
  }
}

/** 等到条件成立，按**次数**而不是墙钟；没等到就说清是什么没发生。 */
export async function until(condition: () => boolean, what: string): Promise<void> {
  for (let attempt = 0; attempt < 300; attempt += 1) {
    if (condition()) return
    await new Promise<void>((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`never happened: ${what}`)
}
