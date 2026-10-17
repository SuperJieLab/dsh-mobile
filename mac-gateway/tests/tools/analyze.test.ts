/**
 * 分析纯函数的判据（R8 期2 Task 5：H5 / H6）。
 *
 * H5 —— 合成记录输入 → 分段 p50/p95/p99 与两套（含停顿 / 排停顿）分布符合
 *       手算的期望值：分析是纯函数、可脱离负载验证（决定 7）。
 * H6 —— 构造已知「先劣化段」的合成记录 → 指认命中该段，次级证据指到该段
 *       字段：指认不是单点猜（决定 6 / 7）。
 *
 * 期望值全部来自手工构造的已知数（字面量），不用与实现相同的方式重算 ——
 * 同义反复的断言什么也证明不了。
 *
 * Run: node --test tests/tools/analyze.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { analyzeRecords, attributeBottleneck, curvePoint, type PerfLike } from '../../tools/bench/analyze.ts'

/** 手工造一条 gw 记录：字段集与 `src/remote/ws.ts` 的 `gwRecord` 对齐。 */
function gw(seq: number, evTime: number, gwRecv: number, gwSend: number, subMs = true): PerfLike {
  return { seg: 'gw', t: gwSend, sessionId: 's1', kind: 'event', seq, evTime, gwRecv, gwSend, bytes: 100 }
}

/** 手工造一条 dev 记录：字段集与 iOS `FollowClient` / 脚本客户端对齐。 */
function dev(seq: number, devRecv: number, devApply: number): PerfLike {
  return { seg: 'dev', t: devApply, sessionId: 's1', kind: 'event', seq, gen: 1, devRecv, devApply, bytes: 90 }
}

test('H5: 无停顿的已知序列 → 分段分布与手算一致', () => {
  // 10 条事件，所有段恒定：t1=10, t2=2, t3=5, t4=1（devRecv = gwSend + 5）。
  const records: PerfLike[] = []
  for (let i = 0; i < 10; i += 1) {
    const evTime = 1_000 + i * 100
    const gwRecv = evTime + 10
    const gwSend = gwRecv + 2
    records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + 5, gwSend + 6))
  }
  const dist = analyzeRecords(records)
  assert.ok(dist !== undefined)
  assert.equal(dist.total, 10)
  assert.equal(dist.pauseCount, 0, 'evenly spaced events contain no pause')

  // 手算：t2 恒 2 → p50=p95=p99=2；t3 恒 5；t4 恒 1；t1 恒 10。
  assert.equal(dist.t2.clean.p50, 2)
  assert.equal(dist.t2.clean.p95, 2)
  assert.equal(dist.t3.clean.p50, 5)
  assert.equal(dist.t4.clean.p95, 1)
  assert.equal(dist.t1.clean.p50, 10)
  // 端到端 = devApply − evTime = 10+2+5+1 = 18。
  assert.equal(dist.e2e.clean.p50, 18)

  // 两套分布：无停顿时含停顿与排停顿同值（决定 7 的退化形态）。
  assert.equal(dist.t2.all.p95, dist.t2.clean.p95)
})

test('H5: 批次停顿被识别，排停顿分布不被它吃掉（R8-B001 的教训）', () => {
  // 20 条正常事件（各段恒定），随后一批 3 条整批晚 400 ms —— 释放批次形态。
  const records: PerfLike[] = []
  for (let i = 0; i < 20; i += 1) {
    const evTime = 1_000 + i * 100
    const gwRecv = evTime + 5
    const gwSend = gwRecv + 1
    records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + 3, gwSend + 4))
  }
  // 批：3 条的 evTime 在正常节拍上，但 devRecv 全挤在 800ms 之后（整批晚 400ms）。
  const batchEvTime = 1_000 + 20 * 100
  for (let i = 20; i < 23; i += 1) {
    const gwRecv = batchEvTime + 5
    const gwSend = gwRecv + 1
    records.push(gw(i, batchEvTime, gwRecv, gwSend), dev(i, gwSend + 403, gwSend + 404))
  }
  const dist = analyzeRecords(records)
  assert.ok(dist !== undefined)
  assert.equal(dist.total, 23)
  assert.equal(dist.pauseCount, 3, 'the whole batch is flagged as pause events')

  // 全量 t3 被停顿吃掉（p95 ≥ 403），排停顿后回到常态 3。
  assert.ok(dist.t3.all.p95 >= 403, `all-samples p95 must include the pause (was ${dist.t3.all.p95})`)
  assert.equal(dist.t3.clean.p95, 3, 'the clean subset excludes the batch')
  assert.equal(dist.t3.clean.n, 20)
})

test('H6: t2 先劣化 → 指认网关段，次级证据指到事件循环读数', () => {
  const records: PerfLike[] = []
  for (let i = 0; i < 20; i += 1) {
    const evTime = 1_000 + i * 100
    const gwRecv = evTime + 1
    const gwSend = gwRecv + 80 // t2 = 80 ms：唯一的大段
    records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + 1, gwSend + 2))
  }
  // 资源采样在场：loopLagP99 = 12.5（网关段的次级证据来源）。
  records.push({ seg: 'res', t: 2_000, loopLagP50: 5, loopLagP99: 12.5, rssMB: 300, heapMB: 120, wsClients: 1 })

  const dist = analyzeRecords(records)
  assert.ok(dist !== undefined)
  const attribution = attributeBottleneck(dist, records)
  assert.equal(attribution.segment, 't2')
  assert.ok(attribution.secondary !== undefined, 'gateway attribution carries secondary evidence')
  assert.equal(attribution.secondary!.field, 'loopLagP99')
  assert.equal(attribution.secondary!.value, 12.5)
})

test('H6: t4 先劣化 → 指认客户端段，次级证据是 t4 自己的分位', () => {
  const records: PerfLike[] = []
  for (let i = 0; i < 20; i += 1) {
    const evTime = 1_000 + i * 100
    const gwRecv = evTime + 1
    const gwSend = gwRecv + 1
    records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + 1, gwSend + 1 + 90)) // t4 = 90
  }
  const dist = analyzeRecords(records)
  assert.ok(dist !== undefined)
  const attribution = attributeBottleneck(dist, records)
  assert.equal(attribution.segment, 't4')
  assert.equal(attribution.secondary!.field, 't4')
  assert.equal(attribution.secondary!.value, dist.t4.clean.p95)
})

test('H6: 指认随数据变 —— 换一批产物结论跟着换', () => {
  // 第一批：t2 大；第二批同样的记录但 t3 大（devRecv 晚 120）。
  const make = (t3: number) => {
    const records: PerfLike[] = []
    for (let i = 0; i < 20; i += 1) {
      const evTime = 1_000 + i * 100
      const gwRecv = evTime + 1
      const gwSend = gwRecv + (t3 > 0 ? 1 : 80)
      records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + t3, gwSend + t3 + 1))
    }
    return records
  }
  const first = attributeBottleneck(analyzeRecords(make(0))!, make(0))
  const second = attributeBottleneck(analyzeRecords(make(120))!, make(120))
  assert.equal(first.segment, 't2')
  assert.equal(second.segment, 't3')
})

test('H5: 旧产物（整数毫秒）与新产物（亚毫秒）同吃 —— 只做减法不依赖分辨力', () => {
  // 与第一条同样的段长，但全部时刻为整数毫秒（R8-B001 时代的产物形状）。
  const records: PerfLike[] = []
  for (let i = 0; i < 10; i += 1) {
    const evTime = 1_000 + i * 100
    const gwRecv = evTime + 10
    const gwSend = gwRecv + 2
    records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + 5, gwSend + 6))
  }
  const dist = analyzeRecords(records)
  assert.ok(dist !== undefined)
  assert.equal(dist.t2.clean.p95, 2)
  assert.equal(dist.t3.clean.p50, 5)
  assert.equal(dist.e2e.clean.p50, 18)
})

// MARK: - 曲线点（Task 6：两条曲线的原料）

test('曲线点：订阅延迟取事件 e2e 的排停顿分布，追平延迟取 opening 的端到端', () => {
  const records: PerfLike[] = []
  // opening：gwRecv=1000, gwSend=1050, devApply=1080 → 追平 = 80 ms。
  records.push(
    { seg: 'gw', t: 1050, sessionId: 's1', kind: 'opening', events: 3, gwRecv: 1000, gwSend: 1050, bytes: 500 },
    { seg: 'dev', t: 1080, sessionId: 's1', kind: 'opening', seq: 2, gen: 1, devRecv: 1060, devApply: 1080, bytes: 480 },
  )
  for (let i = 0; i < 20; i += 1) {
    const evTime = 2_000 + i * 100
    const gwRecv = evTime + 1
    const gwSend = gwRecv + 1
    records.push(gw(i, evTime, gwRecv, gwSend), dev(i, gwSend + 2, gwSend + 3))
  }
  const point = curvePoint(
    { condition: { eventRate: 100, backlogSeq: 3, client: 'script' }, records },
    { seconds: 2 },
  )
  assert.equal(point.valid, true, `a 20-event run with no pause is valid: ${JSON.stringify(point.reasons)}`)
  assert.equal(point.n, 20)
  assert.equal(point.follow.clean.p95, 5, 'follow latency = t1..t4 sums (1+1+2+1)')
  assert.equal(point.catchup.p50, 80, 'catch-up = opening devApply − opening gwRecv')
  assert.equal(point.pauseCount, 0)
})
