/**
 * 用量投影的读取：宿主投影值 → 要发送的快照。
 *
 * 它住在这里而不是 `protocol/`，因为它知道的是**宿主的事**：投影键叫
 * `contextPressure` 与 `contextBreakdown`，分子是 `projectedTokens`（缺则
 * `pressureTokens`），分母是 `contextWindow`。协议层不该知道这些名字 —— 它只该知道
 * 「发不发这一帧」。
 *
 * 占用是客户端第一件**算不出**的事：分子折入所有表面节点，分母只在路由宣告时才
 * 公布，因此它能落在手机所持窗口之外。
 *
 * 两半来自两个独立注册的键，同时对两者取一切带两条规则：分子或分母缺失即「未知」，
 * 绝不是 0%，客户端据此隐藏该行；两键共用一个水位，即切点的 `asOfSeq`，客户端因此
 * 不可能拿新鲜比值配陈旧分解。
 *
 * `asOfSeq` 是这次读的切点，**不是**窗口的水位：窗口按消息数切，可能落后或超前投影
 * 的日志，两者是独立的水位。缓存读（`cachedSnapshot`）因此不够 —— 它给出的切点可能
 * 停在更早的位置。
 */

import type { BreakdownValues, UsageSnapshot } from '../wire/usage.ts'

/**
 * 把投影值的一次切点变成要发送的快照。
 *
 * 分子必需（先 `projectedTokens`，再 `pressureTokens`），`contextWindow` 必需且为正，
 * 两者都必须是整数：投影自身的 schema 如此规定，坏值不得变成百分比。
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
 * 三部分齐备，否则无：三者必须同时在场（残缺的拆分误导多于告知），三个零等同于
 * 缺省 —— 未动过的会话没有可展开之物。
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
