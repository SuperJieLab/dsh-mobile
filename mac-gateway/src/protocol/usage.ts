/**
 * 用量帧的发送判定：什么时候值得重读投影、什么时候值得发一帧。
 *
 * 这里**只有判定**。把投影值变成线上载荷的那一步住在 `upstream/usage.ts` —— 它知道
 * 投影键叫什么，而协议层不该知道。所以本文件认的是事件类型与「值变没变」，不认宿主
 * 的键名。
 *
 * 两件事各自独立：`usageIsTrigger` 说「这条事件可能挪动了投影」，`usageShouldEmit`
 * 说「新读到的值与上一条已发的一样吗」。缺前一条会漏采样，缺后一条会在一个繁忙的
 * turn 里反复发同样的数字。
 */

import type { BreakdownValues, UsagePayload, UsageSnapshot } from '../wire/usage.ts'

/**
 * 一个事件是否构成重读投影的理由。
 *
 * 三种类型携带投影值：`assistant/message` 与 `assistant/attempt` 贡献一次用量采样；
 * `request/context` 是 `contextWindow` 的唯一来源。
 *
 * ⚠️ 上游区分两种用量形状（`data.usage`，或 `data.stream` 的最后一个 chunk）；此处
 * 刻意不分：重读是内存内的同步读，无变化时什么也不发，区分形状只会多一条漏掉采样的路。
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
 * 变了的值要上路，没变的不要（一个繁忙的 turn 会多次稳定下来）；从有变无也是变更
 * 之一 —— 它告诉客户端别再显示旧数字。
 *
 * @param previous - 本流上一条已发送的快照，若有。
 * @param next - 刚读到的快照。
 */
export function usageShouldEmit(previous: UsageSnapshot | undefined, next: UsageSnapshot): boolean {
  return !sameUsage(previous?.usage, next.usage)
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
