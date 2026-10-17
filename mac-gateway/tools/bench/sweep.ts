/**
 * 扫参（R8 期2 Task 6）—— 按清单把不同参数的负载点串着跑（决定 5：一次
 * run 一个进程、扫参串行），产物落一个目录，随后用分析纯函数聚合出两条
 * 曲线的点表并写成 Markdown：
 *
 *     node tools/bench/sweep.ts --out <artifactsDir> --curves <curves.md 路径>
 *
 * 两条曲线（spec 收口判据 1）：
 * ① 订阅延迟 vs 事件率 —— backlog 0，事件率逐级上抬；
 * ② 追平延迟 vs 积压量 —— 事件率固定，打开时预置的 backlog 逐级放大。
 *
 * 每点带负载条件、样本数与有效/无效判定（决定 6：无效点标注而不丢弃），
 * 并附该点的瓶颈段指认（决定 7：排停顿后的分段 p95 最大者）。
 */
import { runBenchScenario, type RunArtifact } from './run.ts'
import { analyzeRecords, attributeBottleneck, curvePoint, type CurvePoint } from './analyze.ts'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/** 订阅延迟曲线：事件率清单（每点秒数统一）。 */
const RATE_SWEEP: { rate: number; seconds: number }[] = [
  { rate: 10, seconds: 10 },
  { rate: 50, seconds: 10 },
  { rate: 100, seconds: 10 },
  { rate: 200, seconds: 10 },
  { rate: 400, seconds: 10 },
  { rate: 800, seconds: 10 },
  { rate: 1600, seconds: 10 },
]

/** 追平延迟曲线：积压量清单（seq 缺口，决定 3）。 */
const BACKLOG_SWEEP: { backlog: number; seconds: number }[] = [
  { backlog: 0, seconds: 8 },
  { backlog: 100, seconds: 8 },
  { backlog: 500, seconds: 8 },
  { backlog: 1000, seconds: 8 },
  { backlog: 2000, seconds: 8 },
  { backlog: 5000, seconds: 8 },
]

const argv = process.argv.slice(2)
const argOf = (name: string): string | undefined => {
  const index = argv.indexOf(name)
  return index >= 0 ? argv[index + 1] : undefined
}

interface PointRow {
  label: string
  point: CurvePoint
  attribution: string
}

function fmtStats(point: CurvePoint): string {
  const clean = point.follow.clean
  const catchup = point.catchup
  const parts = [
    `n=${point.n}`,
    `follow p50/p95/p99 = ${clean.p50.toFixed(1)} / ${clean.p95.toFixed(1)} / ${clean.p99.toFixed(1)} ms`,
    `追平 p50 = ${Number.isNaN(catchup.p50) ? '未获取' : `${catchup.p50.toFixed(1)} ms`}`,
    `停顿 ${point.pauseCount} 条`,
  ]
  if (!point.valid) parts.push(`⚠️ 无效：${point.reasons.join('; ')}`)
  return parts.join(' ｜ ')
}

async function main(): Promise<void> {
  const outDir = argOf('--out') ?? 'tools/bench/artifacts'
  const curvesPath = argOf('--curves')
  mkdirSync(outDir, { recursive: true })
  const rows: PointRow[] = []

  /** 一个产物 → 曲线点行（sweep 两处共用，收口审查 Minor 13）。 */
  const pointOf = (artifact: RunArtifact): { point: CurvePoint; attribution: string } => {
    const point = curvePoint(
      { condition: artifact.condition, records: artifact.records, lagMaxMs: artifact.lag?.maxMs },
      { lagLimitMs: 500 },
    )
    const dist = analyzeRecords(artifact.records)
    const attribution = dist === undefined
      ? '无可对账事件'
      : (() => {
          const b = attributeBottleneck(dist, artifact.records)
          return `${b.segment} p95 ${b.p95.toFixed(1)} ms${b.secondary === undefined ? '' : `（次级 ${b.secondary.field}=${b.secondary.value.toFixed(1)}）`}`
        })()
    return { point, attribution }
  }

  console.log('[sweep] curve 1: follow latency vs event rate')
  for (const { rate, seconds } of RATE_SWEEP) {
    const artifact = await runBenchScenario({ eventRate: rate, payloadShape: 'small', backlogSeq: 0, seconds, outDir })
    const { point, attribution } = pointOf(artifact)
    rows.push({ label: `rate=${rate}`, point, attribution })
    console.log(`[sweep] rate=${rate}: ${fmtStats(point)} ｜ 瓶颈 ${attribution}`)
  }

  console.log('[sweep] curve 2: catch-up latency vs backlog')
  for (const { backlog, seconds } of BACKLOG_SWEEP) {
    const artifact = await runBenchScenario({ eventRate: 50, payloadShape: 'small', backlogSeq: backlog, seconds, outDir })
    const { point, attribution } = pointOf(artifact)
    rows.push({ label: `backlog=${backlog}`, point, attribution })
    console.log(`[sweep] backlog=${backlog}: ${fmtStats(point)} ｜ 瓶颈 ${attribution}`)
  }

  if (curvesPath !== undefined) {
    const rateRows = rows.filter(row => row.label.startsWith('rate='))
    const backlogRows = rows.filter(row => row.label.startsWith('backlog='))
    const doc = [
      '# R8 期2 曲线点表（脚本轮，client=script）',
      '',
      '> 由 `tools/bench/sweep.ts` 生成；每点带负载条件、样本数与有效/无效标注（决定 6），'
        + '瓶颈指认取排停顿后的分段 p95 最大者（决定 7）。'
        + '订阅延迟 = 事件端到端（排停顿）；追平延迟 = opening 的 `devApply − gwRecv`。'
        + '**真机校验轮（client=device）的点另起一节追加，绝不与本表混画同一条曲线**（决定 4）。',
      '',
      '## 曲线 ① 订阅延迟 vs 事件率（backlog=0）',
      '',
      '| 事件率 (ev/s) | 点读数 | 瓶颈指认 |',
      '|---|---|---|',
      ...rateRows.map(row => `| ${row.label.slice('rate='.length)} | ${fmtStats(row.point)} | ${row.attribution} |`),
      '',
      '## 曲线 ② 追平延迟 vs 积压量（rate=50）',
      '',
      '| 积压量 (seq) | 点读数 | 瓶颈指认 |',
      '|---|---|---|',
      ...backlogRows.map(row => `| ${row.label.slice('backlog='.length)} | ${fmtStats(row.point)} | ${row.attribution} |`),
      '',
    ].join('\n')
    writeFileSync(join(curvesPath), doc)
    console.log(`[sweep] curves written to ${curvesPath}`)
  }
}

main().catch(error => {
  console.error(`[sweep] failed: ${String(error)}`)
  process.exitCode = 1
})
