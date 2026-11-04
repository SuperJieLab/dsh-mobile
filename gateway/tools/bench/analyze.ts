/**
 * 分析纯函数（R8 期2 链路 C）—— 产物记录 → 分段分布 / 曲线点 / 瓶颈指认。
 * 输入两端记录与负载条件，输出确定性的结论；不读文件、不碰时钟、不改状态，
 * 同一批产物重跑结论不变（H5 的前提），换一批产物结论随数据变（H6）。
 *
 * 决定 7（分布报两套）：「批次停顿」已被 R8-B001 定成与常规延迟不同机制的一类
 * —— 把它混进 p95 会让「哪段先劣化」被一次停顿改写。每段同时报含停顿与
 * 排停顿两套，停顿事件本身以 `pauseCount` 单独在册（它是真实用户会遇到的）。
 *
 * 对账口径（承期1）：t1 = gwRecv − evTime；t2 = gwSend − gwRecv；
 * t3 = devRecv − gwSend − offset；t4 = devApply − devRecv；
 * 端到端 = devApply − evTime − offset。旧产物（整数毫秒）与新产物（亚毫秒）
 * 同吃 —— 只做减法，不依赖分辨力。
 */

/** 两端记录的最小读面 —— 只声明分析要读的字段，其余不管。 */
export interface PerfLike {
  seg: string
  kind?: unknown
  seq?: unknown
  evTime?: unknown
  gwRecv?: unknown
  gwSend?: unknown
  devRecv?: unknown
  devApply?: unknown
  loopLagP99?: unknown
  [field: string]: unknown
}

/** 一个分段分位切面。 */
export interface SegmentStats {
  n: number
  p50: number
  p95: number
  p99: number
}

export interface SegmentDistributions {
  t1: { all: SegmentStats; clean: SegmentStats }
  t2: { all: SegmentStats; clean: SegmentStats }
  t3: { all: SegmentStats; clean: SegmentStats }
  t4: { all: SegmentStats; clean: SegmentStats }
  e2e: { all: SegmentStats; clean: SegmentStats }
  /** 与上一事件的 devRecv 间隔超过阈值的事件数（批次的形态，单独在册）。 */
  pauseCount: number
  /** 参与对账的事件数（dev 与 gw 按 seq 对上的）。 */
  total: number
}

export interface AnalyzeOptions {
  /** 跨机时钟修正，ms。脚本轮两端同机为 0；真机轮由 clock 采样给出。 */
  offsetMs?: number
  /** 停顿判据：与上一事件 devRecv 的间隔上限，ms。 */
  pauseThresholdMs?: number
}

export interface BottleneckAttribution {
  segment: 't1' | 't2' | 't3' | 't4'
  p95: number
  /** 该段内部的次级证据：网关段 → 事件循环读数（loopLagP99）；客户端段 → t4。 */
  secondary?: { field: 'loopLagP99' | 't4'; value: number }
}

/** 最近邻分位（升序取第 ⌈q/100·n⌉ 个）—— n 条已知分布的手算期望直接对上。 */
function percentile(sorted: readonly number[], q: number): number {
  if (sorted.length === 0) return Number.NaN
  const index = Math.ceil((q / 100) * sorted.length) - 1
  return sorted[Math.min(Math.max(index, 0), sorted.length - 1)]
}

function stats(values: readonly number[]): SegmentStats {
  const sorted = [...values].sort((a, b) => a - b)
  return {
    n: sorted.length,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
  }
}

const num = (value: unknown): number | undefined => (typeof value === 'number' && Number.isFinite(value) ? value : undefined)

/**
 * 两端记录 → 分段分布。dev 与 gw 的事件记录按 `seq` 对上才参与对账
 * （evTime 缺席即跳过，承期1）。无可对账事件时返回 `undefined`。
 */
export function analyzeRecords(records: readonly PerfLike[], options: AnalyzeOptions = {}): SegmentDistributions | undefined {
  const offsetMs = options.offsetMs ?? 0
  const pauseThresholdMs = options.pauseThresholdMs ?? 200

  const gwBySeq = new Map<number, PerfLike>()
  for (const record of records) {
    if (record.seg === 'gw' && record.kind === 'event' && typeof record.seq === 'number') {
      gwBySeq.set(record.seq, record)
    }
  }

  const devEvents = records
    .filter(record => record.seg === 'dev' && record.kind === 'event' && typeof record.seq === 'number')
    .sort((a, b) => (a.seq as number) - (b.seq as number))

  const joined: { t1: number; t2: number; t3: number; t4: number; e2e: number }[] = []
  // devEvents 下标 → joined 下标：与入集同一条判据（五时刻齐 + gw 有同 seq），
  // 否则缺一条记录其后全部错位、停顿集合对到错误的行上（收口审查 Major 1）。
  const joinedIndexOfDev = new Map<number, number>()
  for (const [devIndex, devRecord] of devEvents.entries()) {
    const gwRecord = gwBySeq.get(devRecord.seq as number)
    if (gwRecord === undefined) continue
    const evTime = num(gwRecord.evTime)
    const gwRecv = num(gwRecord.gwRecv)
    const gwSend = num(gwRecord.gwSend)
    const devRecv = num(devRecord.devRecv)
    const devApply = num(devRecord.devApply)
    if (evTime === undefined || gwRecv === undefined || gwSend === undefined || devRecv === undefined || devApply === undefined) {
      continue
    }
    joined.push({
      t1: gwRecv - evTime,
      t2: gwSend - gwRecv,
      t3: devRecv - gwSend - offsetMs,
      t4: devApply - devRecv,
      e2e: devApply - evTime - offsetMs,
    })
    joinedIndexOfDev.set(devIndex, joined.length - 1)
  }
  if (joined.length === 0) return undefined

  // 停顿判定走 devRecv 的到达间隔 —— 批次释放的现场是「整批挤在同一刻到达」。
  // 批内成员彼此间隔 ≈ 0，光看间隔只抓得到批头；后半句补批身：紧跟已停顿
  // 事件、自身跨机延迟也超阈的，属同一批的释放（R8-B001：批内 devRecv 全挤
  // 在 19 ms 内）。
  const paused = new Set<number>()
  for (let i = 0; i < devEvents.length; i += 1) {
    const previous = i > 0 ? num(devEvents[i - 1].devRecv) : undefined
    const current = num(devEvents[i].devRecv)
    if (previous === undefined || current === undefined) continue
    const gap = current - previous
    if (gap > pauseThresholdMs) {
      paused.add(i)
      continue
    }
    if (paused.has(i - 1)) {
      const gwRecord = gwBySeq.get(devEvents[i].seq as number)
      const gwSend = num(gwRecord?.gwSend)
      if (gwSend !== undefined && current - gwSend - offsetMs > pauseThresholdMs) paused.add(i)
    }
  }
  // 对回 joined 的下标：用与入集同判据建好的映射，不再事后推断。
  const cleanIdx: number[] = []
  for (const [devIndex, joinedIndex] of joinedIndexOfDev) {
    if (!paused.has(devIndex)) cleanIdx.push(joinedIndex)
  }
  const pick = (key: 't1' | 't2' | 't3' | 't4' | 'e2e', indices: readonly number[]): number[] =>
    indices.map(index => joined[index][key])

  const both = (key: 't1' | 't2' | 't3' | 't4' | 'e2e') => ({
    all: stats(pick(key, [...joined.keys()])),
    clean: stats(pick(key, cleanIdx)),
  })

  return {
    t1: both('t1'),
    t2: both('t2'),
    t3: both('t3'),
    t4: both('t4'),
    e2e: both('e2e'),
    pauseCount: paused.size,
    total: joined.length,
  }
}

/**
 * 瓶颈段指认：排停顿后分段 p95 的最大者即先劣化段（决定 7）。
 * 合成负载下 t1 不作结论（evTime 是生成器写的，决定 2），指认在 t2 / t3 / t4
 * 之间进行；网关段（t2）附带事件循环读数作次级证据，客户端段（t4）即 fold
 * 分位本身。
 */
export function attributeBottleneck(dist: SegmentDistributions, records?: readonly PerfLike[]): BottleneckAttribution {
  // 全部事件被判停顿时 clean 为空、p95 为 NaN —— NaN 进比较器顺序未定义，
  // 与其吐出「t2 p95 NaN」的假指认，不如显式给 NaN 段（收口审查 Minor 11）。
  const measured: { segment: BottleneckAttribution['segment']; p95: number }[] = [
    { segment: 't2', p95: dist.t2.clean.p95 },
    { segment: 't3', p95: dist.t3.clean.p95 },
    { segment: 't4', p95: dist.t4.clean.p95 },
  ]
  const candidates = measured.filter(candidate => Number.isFinite(candidate.p95))
  if (candidates.length === 0) {
    return { segment: 't2', p95: Number.NaN }
  }
  candidates.sort((a, b) => b.p95 - a.p95)
  const winner = candidates[0]

  let secondary: BottleneckAttribution['secondary']
  if (winner.segment === 't2' && records !== undefined) {
    const resRecords = records.filter(record => record.seg === 'res')
    const lastRes = resRecords[resRecords.length - 1]
    const loopLagP99 = num(lastRes?.loopLagP99)
    if (loopLagP99 !== undefined) secondary = { field: 'loopLagP99', value: loopLagP99 }
  }
  if (winner.segment === 't4') {
    secondary = { field: 't4', value: winner.p95 }
  }
  return { segment: winner.segment, p95: winner.p95, ...(secondary === undefined ? {} : { secondary }) }
}

// MARK: - 曲线点（Task 6：两条曲线的原料）

/** 曲线点读入的一批产物（`runBenchScenario` 的落盘物，真机轮同形状）。 */
export interface CurvePointInput {
  condition: Record<string, unknown>
  records: readonly PerfLike[]
  /** 生成器落后量（决定 2 的旁证，随产物走）—— 判定②用它。 */
  lagMaxMs?: number
}

export interface CurvePoint {
  condition: Record<string, unknown>
  /** 参与订阅延迟对账的事件数。 */
  n: number
  /** 订阅延迟（事件 e2e）——两套分布，曲线取 `clean`。 */
  follow: { all: SegmentStats; clean: SegmentStats }
  /**
   * 追平延迟：opening 的 `devApply − gwRecv − offset` —— 网关装窗口 + 传输
   * + 客户端 fold，一条数覆盖「从打开到追平」。脚本轮同机 offset 为 0。
   */
  catchup: SegmentStats
  pauseCount: number
  valid: boolean
  reasons: string[]
}

export interface CurvePointOptions {
  /** 有效性判定②的落后量上限，ms（决定 6）。 */
  lagLimitMs?: number
  offsetMs?: number
  minEvents?: number
  pauseThresholdMs?: number
}

/** 一批产物 → 一个曲线点（有效性就地重判，决定 6：标注而非丢弃）。 */
export function curvePoint(input: CurvePointInput, options: CurvePointOptions): CurvePoint {
  const minEvents = options.minEvents ?? 20
  const offsetMs = options.offsetMs ?? 0
  const lagLimitMs = options.lagLimitMs ?? 500
  const dist = analyzeRecords(input.records, { offsetMs, pauseThresholdMs: options.pauseThresholdMs })

  // 追平：dev opening 与 gw opening 按出现顺序配对（一轮通常恰好一个）。
  // 被拒的 opening（gw 侧 `rejected`）没有帧可对 —— 排除，别把 dev opening
  // 配到失败的尝试上（收口审查 Minor 12）。
  const gwOpenings = input.records.filter(
    record => record.seg === 'gw' && record.kind === 'opening' && record['rejected'] === undefined,
  )
  const catchupValues: number[] = []
  let gwIndex = 0
  for (const record of input.records) {
    if (record.seg !== 'dev' || record.kind !== 'opening') continue
    const gwOpening = gwOpenings[gwIndex]
    gwIndex += 1
    const devApply = num(record.devApply)
    const gwRecv = num(gwOpening?.gwRecv)
    if (devApply === undefined || gwRecv === undefined) continue
    catchupValues.push(devApply - gwRecv - offsetMs)
  }

  const reasons: string[] = []
  if (dist === undefined || dist.total < minEvents) {
    reasons.push(`event samples ${dist?.total ?? 0} < ${minEvents}`)
  }
  if (input.lagMaxMs !== undefined && input.lagMaxMs > lagLimitMs) {
    reasons.push(`generator lag max ${Math.round(input.lagMaxMs)} ms > ${lagLimitMs} ms`)
  }
  const gens = new Set(input.records.filter(record => record.seg === 'dev').map(record => record.gen))
  if (gens.size > 1) reasons.push(`connection changed generation: ${[...gens].sort().join(',')}`)

  const followStats = dist === undefined
    ? { all: { n: 0, p50: Number.NaN, p95: Number.NaN, p99: Number.NaN }, clean: { n: 0, p50: Number.NaN, p95: Number.NaN, p99: Number.NaN } }
    : { all: dist.e2e.all, clean: dist.e2e.clean }

  return {
    condition: input.condition,
    n: dist?.total ?? 0,
    follow: followStats,
    catchup: stats(catchupValues),
    pauseCount: dist?.pauseCount ?? 0,
    valid: reasons.length === 0,
    reasons,
  }
}
