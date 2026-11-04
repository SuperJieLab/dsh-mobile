/**
 * 场景运行器（R8 期2 链路 B）—— 一条命令跑一个负载点，落一份产物：
 *
 *     node tools/bench/run.ts --rate 50 --payload mixed --backlog 0 --seconds 20 --out <dir>
 *
 * 一次 run = 一个进程（决定 5）：记录在**进程内**收集（`setPerfSink`，不解析
 * stdout），产物是一行 JSONL（契约：`{runId, condition, records, verdict}`）；
 * 样本不足或负载点无效时**非零退出**，verdict 里写明原因（决定 6）。
 *
 * 端口与凭证沿用假宿主的做法：随机高位端口 + 临时目录凭证 —— 扫参不污染
 * 真实的 `~/.dsh` 与凭证文件（决定 4）。
 */
import { mkdirSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { setPerfSink } from '../../src/log.ts'
import { installBench } from './host.ts'
import { startFakeUpstream, type PayloadShape } from './upstream.ts'
import { BenchClient } from './client.ts'
import type { PerfLike } from './analyze.ts'

export interface RunOptions {
  eventRate: number
  payloadShape: PayloadShape
  backlogSeq: number
  sessionId?: string
  /** 一轮跑多久（秒）。 */
  seconds: number
  /** 产物目录；文件名按 `run-<序号>.jsonl` 顺延，同目录可承载一次扫参。 */
  outDir: string
  /** 有效性判据 ①：会话事件样本下限（决定 6）。 */
  minEvents?: number
  /** 有效性判据 ②：生成器落后量上限，ms（决定 2 / 6）。 */
  lagLimitMs?: number
}

export interface RunArtifact {
  runId: string
  condition: {
    sessions: number
    eventRate: number
    payloadShape: PayloadShape
    backlogSeq: number
    /** `script`（本运行器）或 `device`（真机校验轮）—— 两种客户端不混一条曲线。 */
    client: 'script' | 'device'
    seconds: number
  }
  /**
   * 产物里的记录就是 perf 行（`seg` / `t` + 分段字段），所以按 `PerfLike` 收 —— 按
   * `Record<string, unknown>` 收会把「`seg` 是字符串」这个前提丢掉，而分析器正是照它分段。
   */
  records: PerfLike[]
  verdict: { valid: boolean; reasons: string[] }
  /** 生成器落后量（决定 2 的旁证）随产物走 —— 曲线点的有效性判定②要用它。 */
  lag: { samples: number; maxMs: number; lastMs: number }
}

/** 一次场景运行：起网关（假上游）→ 跑固定秒数 → 落产物。 */
export async function runBenchScenario(options: RunOptions): Promise<RunArtifact> {
  const minEvents = options.minEvents ?? 20
  const lagLimitMs = options.lagLimitMs ?? 500
  const sessionId = options.sessionId ?? 'bench-1'

  // 记录进程内收集（决定 5）：sink 先挂上，门控在起网关前打开。
  const gatewayRecords: PerfLike[] = []
  const previousDebug = process.env.DSH_LOG_DEBUG
  setPerfSink(line => {
    gatewayRecords.push(JSON.parse(line.slice(line.indexOf(' {') + 1)) as PerfLike)
  })
  process.env.DSH_LOG_DEBUG = '1'

  const upstream = startFakeUpstream({
    sessions: [sessionId],
    eventRate: options.eventRate,
    payloadShape: options.payloadShape,
    backlogSeq: options.backlogSeq,
  })
  const bench = await installBench({ sessionController: upstream.controller })
  const client = new BenchClient({ port: bench.port, deviceToken: 'bench-device-token', sessionId })
  try {
    await client.start()
    await new Promise(resolve => setTimeout(resolve, options.seconds * 1_000))
  } finally {
    await client.close()
    bench.teardown()
    upstream.stop()
    setPerfSink(() => {})
    if (previousDebug === undefined) delete process.env.DSH_LOG_DEBUG
    else process.env.DSH_LOG_DEBUG = previousDebug
  }

  const devRecords = client.records()
  const eventCount = devRecords.filter(record => record.kind === 'event').length
  const lag = upstream.lag()

  // 有效性判定（决定 6）：三条全满足才有效；无效点标注而不丢弃。
  const reasons: string[] = []
  if (eventCount < minEvents) {
    reasons.push(`event samples ${eventCount} < ${minEvents}`)
  }
  if (lag.maxMs > lagLimitMs) {
    reasons.push(`generator lag max ${Math.round(lag.maxMs)} ms > ${lagLimitMs} ms`)
  }
  const gens = new Set(devRecords.map(record => record.gen))
  if (gens.size > 1 || client.lastError() !== undefined || client.connectionBroke() !== undefined) {
    reasons.push(
      `connection unsettled: gens=${[...gens].join(',')}`
        + `, error=${JSON.stringify(client.lastError())}`
        + `, socket=${client.connectionBroke() ?? 'ok'}`,
    )
  }

  const artifact: RunArtifact = {
    runId: `run-${Date.now()}-${Math.floor(Math.random() * 1_000)}`,
    condition: {
      sessions: 1,
      eventRate: options.eventRate,
      payloadShape: options.payloadShape,
      backlogSeq: options.backlogSeq,
      client: 'script',
      seconds: options.seconds,
    },
    records: [...gatewayRecords, ...devRecords],
    verdict: { valid: reasons.length === 0, reasons },
    lag: { samples: lag.samples, maxMs: lag.maxMs, lastMs: lag.lastMs },
  }

  mkdirSync(options.outDir, { recursive: true })
  // 文件名按目录内已有产物顺延 —— 同一目录承载一次扫参的多个点。
  const existing = new Set<string>()
  try {
    const { readdirSync } = await import('node:fs')
    for (const name of readdirSync(options.outDir)) existing.add(name)
  } catch { /* 目录还不存在时新建即可 */ }
  let index = 1
  while (existing.has(`run-${index}.jsonl`)) index += 1
  appendFileSync(join(options.outDir, `run-${index}.jsonl`), `${JSON.stringify(artifact)}\n`)

  return artifact
}

// MARK: - CLI

const argv = process.argv.slice(2)

function argOf(name: string): string | undefined {
  const index = argv.indexOf(name)
  return index >= 0 ? argv[index + 1] : undefined
}

const eventRate = Number(argOf('--rate') ?? '50')
const payloadShape = (argOf('--payload') ?? 'small') as PayloadShape
const backlogSeq = Number(argOf('--backlog') ?? '0')
const seconds = Number(argOf('--seconds') ?? '20')
const outDir = argOf('--out') ?? 'tools/bench/artifacts'

if (process.argv[1] !== undefined && import.meta.url.endsWith(process.argv[1].split('/').pop() ?? '')) {
  runBenchScenario({ eventRate, payloadShape, backlogSeq, seconds, outDir }).then(artifact => {
    const summary = `events=${artifact.records.filter(r => r.seg === 'dev' && r.kind === 'event').length}`
      + ` valid=${artifact.verdict.valid}`
      + (artifact.verdict.reasons.length > 0 ? ` reasons=${artifact.verdict.reasons.join('; ')}` : '')
    console.log(`[bench] run done: ${summary}`)
    if (!artifact.verdict.valid) process.exitCode = 1
  }, error => {
    console.error(`[bench] run failed: ${String(error)}`)
    process.exitCode = 1
  })
}
