/**
 * 参数化假上游（R8 期2 链路 A）—— 按 `eventRate` / `payloadShape` / `backlogSeq`
 * 产出会话事件流，经由 `sessionController.follow` 这个**网关泵消费的同一接缝**
 * 交给真插件；网关代码里没有任何「上游是不是假的」的分支。
 *
 * 决定 2（生成器时钟解耦）：事件的 `time`（→ 网关 `evTime`）由目标节拍给出，
 * 产出时刻落后于目标时刻的差记作「生成器落后量」并聚合暴露 —— 它是负载点
 * 有效性判定（决定 6）的旁证。积压不靠人为拖延：生成器只在被消费时产出，
 * 消费跟不上时落后量自然变大。
 *
 * 决定 3（积压以 seq 计）：`backlogSeq` = 打开帧携带的历史条数，续发事件的
 * `seq` 接着走 —— 与协议「只补差量」的语义对齐，产物记缺口条数而非秒数。
 */

/** 事件载荷形状。`small` 恒定小载荷；`mixed` 在几档尺寸间循环。 */
export type PayloadShape = 'small' | 'mixed'

export interface UpstreamParams {
  /** 提供哪些会话（每个会话独立的 seq 与日志）。 */
  sessions: readonly string[]
  /** 目标事件率：每条 follow 流每秒的事件条数。 */
  eventRate: number
  payloadShape: PayloadShape
  /** 打开时预置的历史条数（seq 缺口的别名，决定 3）。 */
  backlogSeq: number
}

/** 生成器落后量的聚合读数（决定 2 的旁证）。 */
export interface LagSummary {
  /** 已产出的事件数（不含 backlog 预置）。 */
  samples: number
  /** 落后量的最大值，ms。 */
  maxMs: number
  /** 最近一条的落后量，ms。 */
  lastMs: number
}

export interface UpstreamHandle {
  /** 装进假宿主的 `sessionController` 面。 */
  controller: {
    follow(
      request: { address: { kind: 'session'; sessionId: string }; maxMessages?: number },
      signal: AbortSignal,
    ): AsyncIterable<
      | { type: 'snapshot'; cursor: number; records: readonly { type: 'event'; event: unknown }[]; hasMore: boolean }
      | { type: 'event'; event: unknown }
    >
  }
  /** 累计产出条数（不含 backlog）。 */
  produced(): number
  lag(): LagSummary
  stop(): void
}

/** `mixed` 的尺寸档（字节近似）。 */
const MIXED_SIZES = [64, 256, 1024, 2048]

/** 载荷形状 → 一段文本。纯函数，seq 决定 `mixed` 档位（可复现）。 */
function payloadOf(shape: PayloadShape, seq: number): string {
  if (shape === 'small') return 'x'.repeat(64)
  return 'x'.repeat(MIXED_SIZES[seq % MIXED_SIZES.length])
}

/** 一条合成事件：`time` 是目标节拍时刻（epoch ms），网关侧即 `evTime`。 */
function eventAt(seq: number, dueMs: number, shape: PayloadShape): Record<string, unknown> {
  return { type: 'assistant/message', seq, time: dueMs, data: { text: payloadOf(shape, seq) } }
}

/** 每会话的状态：日志（含 backlog）与下一个 seq。 */
interface SessionState {
  log: Record<string, unknown>[]
  nextSeq: number
}

export function startFakeUpstream(params: UpstreamParams): UpstreamHandle {
  const states = new Map<string, SessionState>(params.sessions.map(id => [id, { log: [], nextSeq: 0 }]))
  const lagSamples: number[] = []
  let producedCount = 0
  let stopped = false

  const handle: UpstreamHandle = {
    controller: {
      follow(request, signal) {
        const state = states.get(request.address.sessionId)
        if (state === undefined) {
          throw new Error(`bench upstream has no session "${request.address.sessionId}"`)
        }
        return followStream(state, request, signal)
      },
    },
    produced: () => producedCount,
    lag: () => ({
      samples: lagSamples.length,
      maxMs: lagSamples.length === 0 ? 0 : Math.max(...lagSamples),
      lastMs: lagSamples.length === 0 ? 0 : lagSamples[lagSamples.length - 1],
    }),
    stop: () => { stopped = true },
  }
  return handle

  /** 一条 follow 流：先 backlog 快照，再按目标节拍续发。 */
  async function* followStream(
    state: SessionState,
    request: { maxMessages?: number },
    signal: AbortSignal,
  ): AsyncIterable<
    | { type: 'snapshot'; cursor: number; records: readonly { type: 'event'; event: unknown }[]; hasMore: boolean }
    | { type: 'event'; event: unknown }
  > {
    // 首次打开：预置 backlog（决定 3）—— 时间均匀铺在过去，seq 从 0 起。
    if (state.log.length === 0 && params.backlogSeq > 0) {
      const intervalMs = 1_000 / params.eventRate
      const now = Date.now()
      for (let i = 0; i < params.backlogSeq; i += 1) {
        state.log.push(eventAt(i, now - (params.backlogSeq - i) * intervalMs, params.payloadShape))
      }
      state.nextSeq = params.backlogSeq
    }

    const window = request.maxMessages ?? 500
    const records = state.log.slice(-window).map(event => ({ type: 'event' as const, event }))
    yield { type: 'snapshot', cursor: state.nextSeq - 1, records, hasMore: state.log.length > window }

    const intervalMs = 1_000 / params.eventRate
    let nextDue = Date.now()
    while (!signal.aborted && !stopped) {
      const due = nextDue
      const now = Date.now()
      if (now < due) {
        await sleepUntil(due, signal)
        if (signal.aborted || stopped) return
      }
      const event = eventAt(state.nextSeq, due, params.payloadShape)
      state.nextSeq += 1
      state.log.push(event)
      producedCount += 1
      lagSamples.push(Date.now() - due)
      yield { type: 'event', event }
      nextDue = due + intervalMs
    }
  }
}

/** 睡到指定时刻；取消信号随时打断（分段睡，不吞取消）。 */
async function sleepUntil(dueMs: number, signal: AbortSignal): Promise<void> {
  while (!signal.aborted) {
    const remain = dueMs - Date.now()
    if (remain <= 0) return
    await new Promise(resolve => setTimeout(resolve, Math.min(remain, 5)))
  }
}
