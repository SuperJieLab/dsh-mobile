/**
 * 用量契约 (M6)：上下文占用，从两个投影值到一个帧载荷 —— 纯函数，
 * 与本目录其他文件一致。
 *
 * 占用是客户端第一件**算不出**的事：分子折入所有表面节点，分母只在路由
 * 宣告时才公布，因此它能落在手机所持窗口之外。参考 UI 做同样的算术
 * （`ui-conversation/src/client/context-occupancy.ts:15-25`）：
 * `projectedTokens ?? pressureTokens` 比 `contextWindow`，封顶并取整 ——
 * 这里不重推宿主已知的事（§2.1）。
 *
 * 两半来自**两个独立注册的键**（`@deepseek-ai/dsh-token-meter`：
 * `contextPressure`、`contextBreakdown`，各自独立条款），同时对两者取一切
 * 带两条规则：分子或分母缺失即「未知」，绝不是 0%，客户端据此隐藏该行
 * （§3.1 决定 4，判据 U2）；两键共用一个水位，即切点的 `asOfSeq`，客户端
 * 因此不可能拿新鲜比值配陈旧分解（§3.1 决定 6，判据 U7）。
 *
 * 线上形状见 dev/protocol.md §4.4；`asOfSeq` 盖哪个读、以及为何保守的
 * 缓存读是错的，见 dev/plans/M6-presentation-layer.md §3.1 决定 3。
 */

/**
 * 构成的一半：对下一个请求的启发式 system / tools / message 拆分。
 * 刻意**不是** `usedTokens` 的分解 —— 估计器低估 CJK 文本与 JSON schema，
 * 三者相加永远对不齐锚定的分子（§3.1 决定 6）。
 */
export interface BreakdownValues {
  systemTokens: number
  toolsTokens: number
  messageTokens: number
}

/** 手机所画之物：一个比值，以及它描述多大的上下文。 */
export interface UsagePayload {
  /** 分子：以 provider 为锚，此处绝不估计。 */
  usedTokens: number
  /** 分母。 */
  contextWindow: number
  /**
   * 仅当三部分全部已知且不全为零时存在；缺省省略展开行，绝不省略比值
   * （§3.1 决定 6）。
   */
  breakdown?: BreakdownValues
}

/**
 * 一个水位加上在该水位下可显示之物。`usage` 缺省是陈述，不是缺口：
 * 正在显示更旧内容的客户端据此清掉它。
 */
export interface UsageSnapshot {
  /** 读到这些值时的切点 —— 日志的水位，不是窗口边界。 */
  asOfSeq: number
  usage?: UsagePayload
}

/**
 * 把投影值的一次切点变成要发送的快照。
 *
 * 分子必需（先 `projectedTokens`，再 `pressureTokens`），`contextWindow`
 * 必需且为正，两者都必须是整数：投影自身的 schema 如此规定，坏值不得
 * 变成百分比（§3.1 决定 4，判据 U4）。
 *
 * @param values - 按投影键原样读到的投影值，不透明。
 * @param asOfSeq - 读这些值时的水位。
 * @returns 快照；无可显示之物时 `usage` 缺省。
 */
export function usageSnapshotOf(values: Readonly<Record<string, unknown>>, asOfSeq: number): UsageSnapshot {
  const pressure = asRecord(values['contextPressure'])
  const projected = nonNegativeInteger(pressure?.['projectedTokens'])
  const sampled = nonNegativeInteger(pressure?.['pressureTokens'])
  const usedTokens = projected ?? sampled
  const contextWindow = positiveInteger(pressure?.['contextWindow'])
  if (usedTokens === undefined || contextWindow === undefined) return { asOfSeq }
  const breakdown = breakdownOf(asRecord(values['contextBreakdown']))
  return {
    asOfSeq,
    usage: {
      usedTokens,
      contextWindow,
      ...(breakdown === undefined ? {} : { breakdown }),
    },
  }
}

/**
 * 一个事件是否构成重读投影的理由。
 *
 * 三种类型携带投影值（`dsh-token-meter` 的 `usage-projection.ts`）：
 * `assistant/message` 与 `assistant/attempt` 贡献一次用量采样
 * （`usageOf`，`:82-86`，应用于 `:128`）；`request/context` 是
 * `contextWindow` 的唯一来源（`:181-191`）。
 *
 * ⚠️ 上游区分两种用量形状（`data.usage`，或 `data.stream` 的最后一个
 * chunk）；此处刻意不分：重读是内存内的同步读，无变化时什么也不发，
 * 区分形状只会多一条漏掉采样的路（§3.1 决定 3，判据 U5）。
 *
 * @param event - 事件，仅按类型判定。
 */
export function usageIsTrigger(event: { type: string }): boolean {
  return event.type === 'assistant/message'
    || event.type === 'assistant/attempt'
    || event.type === 'request/context'
}

/**
 * 新快照是否值得发一帧。
 *
 * 变了的值要上路，没变的不要（一个繁忙的 turn 会多次稳定下来）；从有变无
 * 也是变更之一 —— 它告诉客户端别再显示旧数字（§3.1 决定 3，判据 U3）。
 *
 * @param previous - 本流上一条已发送的快照，若有。
 * @param next - 刚读到的快照。
 */
export function usageShouldEmit(previous: UsageSnapshot | undefined, next: UsageSnapshot): boolean {
  return !sameUsage(previous?.usage, next.usage)
}

/** 非负整数，否则 `undefined` —— 投影自身的数值契约。 */
function nonNegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined
}

/** 正整数，否则 `undefined` —— 零容量不可作除数。 */
function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : undefined
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined
  return value as Record<string, unknown>
}

/**
 * 三部分齐备，否则无：三者必须同时在场（残缺的拆分误导多于告知），三个零
 * 等同于缺省 —— 未动过的会话没有可展开之物（§3.1 决定 6，判据 U8）。
 */
function breakdownOf(values: Record<string, unknown> | undefined): BreakdownValues | undefined {
  if (values === undefined) return undefined
  const systemTokens = nonNegativeInteger(values['systemTokens'])
  const toolsTokens = nonNegativeInteger(values['toolsTokens'])
  const messageTokens = nonNegativeInteger(values['messageTokens'])
  if (systemTokens === undefined || toolsTokens === undefined || messageTokens === undefined) return undefined
  if (systemTokens === 0 && toolsTokens === 0 && messageTokens === 0) return undefined
  return { systemTokens, toolsTokens, messageTokens }
}

function sameUsage(a: UsagePayload | undefined, b: UsagePayload | undefined): boolean {
  if (a === undefined || b === undefined) return a === b
  return a.usedTokens === b.usedTokens
    && a.contextWindow === b.contextWindow
    && sameBreakdown(a.breakdown, b.breakdown)
}

function sameBreakdown(a: BreakdownValues | undefined, b: BreakdownValues | undefined): boolean {
  if (a === undefined || b === undefined) return a === b
  return a.systemTokens === b.systemTokens
    && a.toolsTokens === b.toolsTokens
    && a.messageTokens === b.messageTokens
}
