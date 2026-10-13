/**
 * 性能记录通道（R8 期1）—— 观测出口的一支：与文本日志同一个 `[dsh]` 家族、
 * 同一个 debug 门控，但承载的是「挂 seq 的四段边界记录」而不是人读的消息。
 * 行格式：`ISO8601 [dsh][perf][模块] {json}`。
 *
 * 字段集与语义（seg / t / sessionId / seq 与各 seg 的附加字段）是两端契约，
 * 见 `dev/features/R8-e2e-latency-bench/plans/R8-1-observability-budget.md` 节四；
 * 本文件只负责拼行与出口，不做任何段间算术 —— 那是期2 分析层的事。
 *
 * 出口唯一纪律的落地：调用面统一从 `log.ts` 导入 `perfRecord`（那里 re-export），
 * 物理写盘在本文件 —— 与 `log.ts` 的 `write()` 同族（同标签、同门控、同 stderr）。
 * `setPerfSink` 是测试后门：只有测试会替换行的去向。
 */

/** 记录来自哪一端 —— 契约的四个 seg 值。 */
export type PerfSeg = 'gw' | 'dev' | 'res' | 'clock'

/**
 * 一条性能记录。`seg` / `t` / `sessionId` / `seq` 是公共字段；其余按 seg 不同：
 * `gw` 带 evTime / gwRecv / gwSend / bytes，`dev` 带 devRecv / devApply，
 * `clock` 带 serverTime，`res` 带 loopLagP50 / loopLagP99 / rssMB / heapMB /
 * wsClients。缺的字段就是「这一条不适用」，不填默认值。
 */
export interface PerfRecord {
  readonly seg: PerfSeg
  /** 该边界的本地 ms 时刻（epoch ms）。 */
  readonly t: number
  readonly sessionId?: string
  readonly seq?: number
  readonly [field: string]: unknown
}

/**
 * 与 `log.ts` 的 `debugEnabled` 是同一个开关（`DSH_LOG_DEBUG=1`）；此处为函数
 * 形式而不是加载期常量，是为了测试能翻转它。
 */
export function perfEnabled(): boolean {
  return process.env.DSH_LOG_DEBUG === '1'
}

/**
 * 拼一行。纯函数 —— 时间由调用方给入（测试注入时钟，默认取当下）。
 * JSON 的键序跟随记录对象的字面顺序，消费方按字段名读，不依赖键序。
 */
export function perfLine(module: string, record: PerfRecord, now: Date = new Date()): string {
  return `${now.toISOString()} [dsh][perf][${module}] ${JSON.stringify(record)}`
}

/** 行的去向。默认 stderr；只有测试会替换它。 */
let sink: (line: string) => void = (line) => {
  process.stderr.write(`${line}\n`)
}

export function setPerfSink(next: (line: string) => void): void {
  sink = next
}

/** 记一条。门控关时什么都不做 —— 默认运行零开销、零噪音。 */
export function perfRecord(module: string, record: PerfRecord): void {
  if (!perfEnabled()) return
  sink(perfLine(module, record))
}
