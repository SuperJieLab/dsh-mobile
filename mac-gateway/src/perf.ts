/**
 * 性能记录通道（R8 期1）—— 观测出口的一支：与文本日志同一个 `[dsh]` 家族、
 * 同一个 debug 门控，但承载的是「挂 seq 的四段边界记录」而不是人读的消息。
 * 行格式：`<本机时间带偏移> [dsh][perf][模块] {json}`，时间戳与文本日志共用
 * `timestamp.ts` 的 `logTimestamp` —— 两条出口要能被放在一起按时间对照。
 *
 * 字段集与语义（seg / t / sessionId / seq 与各 seg 的附加字段）**是两端契约**：
 * 改字段就是改协议，采集脚本与预算表都按它读。本文件只负责拼行与出口，
 * 不做任何段间算术 —— 差值、分位与瓶颈指认属分析层。
 *
 * 出口唯一纪律的落地：调用面统一从 `log.ts` 导入 `perfRecord`（那里 re-export），
 * 物理写盘在本文件 —— 与 `log.ts` 的 `write()` 同族（同标签、同门控、同 stderr）。
 * `setPerfSink` 是测试后门：只有测试会替换行的去向。
 *
 * **验证方式**：它的判据是**真机采集**（采集卡与 `budget.md`），**不在单元测试面内** ——
 * 写在这里是为了别让后来者误以为它被单测验过。
 */

import { monitorEventLoopDelay, performance } from 'node:perf_hooks'

import { logTimestamp } from './timestamp.ts'

/**
 * 亚毫秒 epoch 时刻（R8 期2 精度加精）：`Date.now()` 只有整数毫秒，而 t2 段
 * （`gwRecv` → `gwSend`）正是瓶颈指认要看的段 —— R8-B001 实测它恒为 0，
 * 1 ms 的分辨力看不见它。字段名与语义不变，只换取时刻的钟。
 */
export function perfNow(): number {
  return performance.timeOrigin + performance.now()
}

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
 *
 * 时间戳与文本日志同一个函数（`logTimestamp`）：两条出口必须能被放在一起按时间对照，
 * 而「同一毫秒在两处写法不同」会让那种对照退化成手工换算。
 */
export function perfLine(module: string, record: PerfRecord, now: Date = new Date()): string {
  return `${logTimestamp(now)} [dsh][perf][${module}] ${JSON.stringify(record)}`
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

/** 一条资源采样的输入（R8 期1 链路 B）—— 采样器从系统读快照，本形状是它的纯函数入参。 */
export interface ResourceSample {
  /** 事件循环延迟直方图的 p50，毫秒。 */
  readonly loopLagP50: number
  /** 事件循环延迟直方图的 p99，毫秒。 */
  readonly loopLagP99: number
  /** 进程 RSS，MB。 */
  readonly rssMB: number
  /** 堆已用，MB。 */
  readonly heapMB: number
  /** 当前接入的流客户端数。 */
  readonly wsClients: number
}

/** 快照 → res 记录。纯函数：段名固定 `res`，t 取采样时刻。 */
export function resourceRecord(sample: ResourceSample, now: Date = new Date()): PerfRecord {
  return { seg: 'res', t: now.getTime(), ...sample }
}

/**
 * 周期性采一条资源记录（R8 期1 链路 B）。事件循环是 dsh 全进程共享面 ——
 * 读数只做趋势，归因到期2 微观基准。返回停止函数。
 *
 * 采样节拍内的清零：直方图读后即 reset，每条记录只覆盖刚过去的这个周期。
 * `module` 由调用方给（标签集中在 log.ts 登记，本文件不引它 —— 引了会成环）。
 */
export function startResourceSampler(options: {
  intervalMs: number
  module: string
  clientCount: () => number
  emit?: (module: string, record: PerfRecord) => void
}): () => void {
  const histogram = monitorEventLoopDelay({ resolution: 20 })
  histogram.enable()
  const emit = options.emit ?? perfRecord
  const timer = setInterval(() => {
    const memory = process.memoryUsage()
    emit(
      options.module,
      resourceRecord({
        loopLagP50: histogram.percentile(50) / 1e6,
        loopLagP99: histogram.percentile(99) / 1e6,
        rssMB: Math.round((memory.rss / 1024 / 1024) * 10) / 10,
        heapMB: Math.round((memory.heapUsed / 1024 / 1024) * 10) / 10,
        wsClients: options.clientCount(),
      }),
    )
    histogram.reset()
  }, options.intervalMs)
  return () => {
    clearInterval(timer)
    histogram.disable()
  }
}
