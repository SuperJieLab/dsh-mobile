/**
 * 进程内的指标表。写在各个处理点，读在 `GET /metrics`。
 *
 * 与 `perf` 的分工不是「重要程度」，是**读的时机**：`perf` 是 debug 门控下的逐条记录，
 * 给真机采集用 —— 出事时要事先开着才看得到；这里是常驻计数器，拉模式，随时 curl
 * 一下就能看。**「出事时才发现开关没开」是最常见的一种观测不到。**
 *
 * 只做网关。客户端指标在单用户下没有趋势可看；而 RSS / 事件循环延迟 / 请求失败率
 * 是**容量问题**，与用户数无关 —— 那才是真有意义的指标。
 *
 * 资源读数**复用已有的 5 秒采样器**（`startResourceSampler`），不另开一份直方图：
 * 两份采样各自跑，读出来的 p99 还会互相不一致。
 */

import type { ResourceSample } from './perf.ts'

/** 一个带标签的计数。标签已按 key 排好序，直接拼成一行。 */
interface Sample {
  readonly name: string
  /** `{a="1",b="2"}`；无标签时是空串。 */
  readonly labels: string
  value: number
}

/** 指标的静态描述。`help` 是给人看的，`type` 决定 Prometheus 怎么聚合它。 */
interface Descriptor {
  readonly help: string
  readonly type: 'counter' | 'gauge'
}

const DESCRIPTORS: Record<string, Descriptor> = {
  dsh_rpc_requests_total: {
    help: 'RPC 请求数，按 op 与结果（ok / refused）。refused 里含协议拒绝与端口缺席。',
    type: 'counter',
  },
  dsh_rss_bytes: { help: '进程常驻内存。', type: 'gauge' },
  dsh_heap_used_bytes: { help: 'V8 堆已用。', type: 'gauge' },
  dsh_event_loop_lag_seconds: {
    help: '事件循环延迟分位，取自最近一个采样周期（采样器每次读后清零）。',
    type: 'gauge',
  },
  dsh_ws_clients: { help: '当前接入的流客户端数。', type: 'gauge' },
}

/**
 * 指标表。
 *
 * 计数器按「名字 + 标签」聚合，标签**按 key 排序**拼进 key —— 同一组标签换一个书写顺序
 * 会变成两条序列，那是把一次统计拆成两半。
 */
export class Metrics {

  private readonly counters = new Map<string, Sample>()
  /** 最近一次资源采样。采样器本来就在跑，这里只存它交来的那一份。 */
  private runtime: ResourceSample | undefined

  /** 记一次计数。`labels` 的 key 顺序不影响结果。 */
  count(name: string, labels: Record<string, string> = {}, by = 1): void {
    const rendered = renderLabels(labels)
    const key = `${name}${rendered}`
    const existing = this.counters.get(key)
    if (existing === undefined) {
      this.counters.set(key, { name, labels: rendered, value: by })
    } else {
      existing.value += by
    }
  }

  /** 收下一次资源采样。由 `startResourceSampler` 的 `onSample` 调。 */
  updateRuntime(sample: ResourceSample): void {
    this.runtime = sample
  }

  /** Prometheus 文本格式（version 0.0.4）。 */
  render(): string {
    const lines: string[] = []

    // 计数器：按名字分组，每个名字一段（`# TYPE` 每个名字只能出现一次）。
    // **没登记的名字不输出**：拼错一个字母会产出没有 `# TYPE` 的孤儿序列，
    // 而抓取端会把它当成另一条指标收下 —— 静默多出一条，没人会发现。
    for (const [name, samples] of groupByName(this.counters.values())) {
      const descriptor = DESCRIPTORS[name]
      if (descriptor === undefined) continue
      lines.push(...header(name, descriptor))
      for (const sample of samples) {
        lines.push(`${sample.name}${sample.labels} ${sample.value}`)
      }
    }

    // 资源读数：来自最近一次采样。没有采样过就一条都不出 —— 报 0 会被读成
    // 「内存占用为零」，那比缺一条更坏。
    const runtime = this.runtime
    if (runtime !== undefined) {
      lines.push(...header('dsh_rss_bytes', DESCRIPTORS.dsh_rss_bytes))
      lines.push(`dsh_rss_bytes ${Math.round(runtime.rssMB * 1024 * 1024)}`)

      lines.push(...header('dsh_heap_used_bytes', DESCRIPTORS.dsh_heap_used_bytes))
      lines.push(`dsh_heap_used_bytes ${Math.round(runtime.heapMB * 1024 * 1024)}`)

      lines.push(...header('dsh_ws_clients', DESCRIPTORS.dsh_ws_clients))
      lines.push(`dsh_ws_clients ${runtime.wsClients}`)

      lines.push(...header('dsh_event_loop_lag_seconds', DESCRIPTORS.dsh_event_loop_lag_seconds))
      lines.push(`dsh_event_loop_lag_seconds{quantile="0.5"} ${runtime.loopLagP50}`)
      lines.push(`dsh_event_loop_lag_seconds{quantile="0.99"} ${runtime.loopLagP99}`)
    }

    return lines.length === 0 ? '' : `${lines.join('\n')}\n`
  }
}

function header(name: string, descriptor: Descriptor): string[] {
  return [`# HELP ${name} ${descriptor.help}`, `# TYPE ${name} ${descriptor.type}`]
}

function groupByName(samples: Iterable<Sample>): Map<string, Sample[]> {
  const grouped = new Map<string, Sample[]>()
  for (const sample of samples) {
    const bucket = grouped.get(sample.name)
    if (bucket === undefined) grouped.set(sample.name, [sample])
    else bucket.push(sample)
  }
  // 名字排序：同一份状态每次渲染出来逐字相同，diff 才有意义。
  return new Map([...grouped.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
}

/**
 * 标签拼成 `{a="1",b="2"}`，**按 key 排序**。
 *
 * 排序与日志字段同一条纪律：顺序不固定的话，同一组标签会变成两条序列，
 * 而「这行变了没」每次都要重新看。
 */
function renderLabels(labels: Record<string, string>): string {
  const keys = Object.keys(labels).sort()
  if (keys.length === 0) return ''
  const parts = keys.map((key) => `${key}="${escapeLabel(labels[key])}"`)
  return `{${parts.join(',')}}`
}

/** Prometheus 的标签值转义：反斜杠、双引号、换行。 */
function escapeLabel(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')
}
