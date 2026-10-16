/**
 * 合成负载与假宿主的判据（R8 期2 Task 1）。
 *
 * H1 —— 假上游按 `eventRate` 产出事件，消费侧收到的条数与目标一致（容差内）：
 *       负载真的可参数化，不是「跑起来了」就算。
 * H2 —— 假宿主缺任一面时高声失败并指出缺哪一面：cordis 对缺面的真实反应是
 *       静默扣住 fiber，断言必须在 `apply` 之前替它喊出来（决定 1）。
 *
 * 观测接缝 = `sessionController.follow` —— 网关泵消费的就是这一个接口，
 * 测试直接站在同一个缝上计数，不绕道任何内部。
 *
 * Run: node --test tests/tools/upstream.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { defaultBenchFaces, installBench, missingFaces } from '../../tools/bench/host.ts'
import { startFakeUpstream } from '../../tools/bench/upstream.ts'

// MARK: - H2 缺面高声失败

test('H2: 九面齐全的集合不缺任何面', () => {
  assert.deepEqual(missingFaces(defaultBenchFaces()), [])
})

test('H2: 缺一个面时点名那一个面', () => {
  const faces = defaultBenchFaces()
  delete (faces as Record<string, unknown>).agents
  assert.deepEqual(missingFaces(faces), ['agents'])
})

test('H2: 缺多个面时全部点名', () => {
  const faces = defaultBenchFaces()
  delete (faces as Record<string, unknown>).sessionQuery
  delete (faces as Record<string, unknown>).typertGateway
  assert.deepEqual(missingFaces(faces).sort(), ['sessionQuery', 'typertGateway'])
})

test('H2: installBench 缺面时抛错且错误信息点名缺的那一面', async () => {
  await assert.rejects(() => installBench({ agents: undefined }), /agents/)
})

// MARK: - 装配冒烟：九面齐备时监听器真的起来（不是「起来了但没监听」）

test('九面齐备的假宿主把真插件装配到可应答', { timeout: 10_000 }, async () => {
  const bench = await installBench()
  try {
    const response = await fetch(`http://127.0.0.1:${bench.port}/`)
    assert.equal(response.status, 200)
  } finally {
    bench.teardown()
  }
})

// MARK: - H1 事件率可参数化

/** 站在 follow 接缝上数一秒内收到的事件条数。 */
async function countEvents(rate: number, windowMs: number): Promise<number> {
  const upstream = startFakeUpstream({
    sessions: ['s1'],
    eventRate: rate,
    payloadShape: 'small',
    backlogSeq: 0,
  })
  const abort = new AbortController()
  let count = 0
  try {
    const stream = upstream.controller.follow(
      { address: { kind: 'session', sessionId: 's1' }, assistantStream: true },
      abort.signal,
    )
    const start = Date.now()
    for await (const frame of stream) {
      if (frame.type === 'event') count += 1
      if (Date.now() - start >= windowMs) break
    }
  } finally {
    abort.abort()
    upstream.stop()
  }
  return count
}

test('H1: eventRate 400/s 跑 1 秒，收到 ~400 条（容差 25%）', { timeout: 10_000 }, async () => {
  const count = await countEvents(400, 1_000)
  const target = 400
  assert.ok(
    Math.abs(count - target) / target < 0.25,
    `expected ~${target} events in 1s at rate 400, got ${count}`,
  )
})

test('H1: 事件率减半，产出随之减半（参数真的在起作用）', { timeout: 10_000 }, async () => {
  const fast = await countEvents(400, 800)
  const slow = await countEvents(200, 800)
  // 各自与目标比，再互相比：两次都合容差且比值接近 2。
  assert.ok(Math.abs(fast - 320) / 320 < 0.25, `rate 400 in 0.8s: expected ~320, got ${fast}`)
  assert.ok(Math.abs(slow - 160) / 160 < 0.25, `rate 200 in 0.8s: expected ~160, got ${slow}`)
  assert.ok(fast > slow * 1.5, `halving the rate must visibly halve the output: ${fast} vs ${slow}`)
})

test('H1: 生成器落后量随产出被记录（决定 2 的旁证在场）', async () => {
  const upstream = startFakeUpstream({
    sessions: ['s1'],
    eventRate: 50,
    payloadShape: 'small',
    backlogSeq: 0,
  })
  const abort = new AbortController()
  try {
    const stream = upstream.controller.follow(
      { address: { kind: 'session', sessionId: 's1' }, assistantStream: true },
      abort.signal,
    )
    for await (const frame of stream) {
      if (frame.type === 'event') break
    }
  } finally {
    abort.abort()
    upstream.stop()
  }
  const lag = upstream.lag()
  assert.ok(lag.samples >= 1, 'at least one lag sample per produced event')
  assert.ok(lag.maxMs >= 0, 'lag is a non-negative quantity')
})

// MARK: - backlog 与 seq 连续性（决定 3：积压以 seq 缺口计）

test('backlogSeq=N 时打开帧携带 N 条历史，续发事件 seq 连着走', { timeout: 10_000 }, async () => {
  const upstream = startFakeUpstream({
    sessions: ['s1'],
    eventRate: 100,
    payloadShape: 'small',
    backlogSeq: 7,
  })
  const abort = new AbortController()
  try {
    const stream = upstream.controller.follow(
      { address: { kind: 'session', sessionId: 's1' }, assistantStream: true },
      abort.signal,
    )
    let snapshotCursor: number | undefined
    const liveSeqs: number[] = []
    for await (const frame of stream) {
      if (frame.type === 'snapshot') {
        snapshotCursor = frame.cursor
        assert.equal(frame.records.length, 7, 'the opening carries exactly the backlog')
        assert.equal(frame.records[0].event.seq, 0)
        assert.equal(frame.records[6].event.seq, 6)
      } else if (frame.type === 'event') {
        liveSeqs.push(frame.event.seq)
        if (liveSeqs.length >= 3) break
      }
    }
    assert.equal(snapshotCursor, 6, 'the cursor marks the last backlog seq, inclusive')
    assert.deepEqual(liveSeqs, [7, 8, 9], 'live events continue where the backlog ends')
  } finally {
    abort.abort()
    upstream.stop()
  }
})
