/**
 * 「这条事件可能挪动了投影」的判定。
 *
 * 只有判定，没有值、没有形状：把投影值变成线上载荷的那一步归客户端（`UsageView`），
 * 这一层只回答「要不要重读」。三个类型携带投影值：`assistant/message` 与
 * `assistant/attempt` 贡献一次用量采样；`request/context` 是 `contextWindow` 的唯一来源。
 *
 * ⚠️ 上游区分两种用量形状（`data.usage`，或 `data.stream` 的最后一个 chunk）；此处
 * 刻意不分：重读是内存内的同步读，无变化时什么也不发，区分形状只会多一条漏掉采样的路。
 */

export function usageIsTrigger(event: { type: string }): boolean {
  return event.type === 'assistant/message'
    || event.type === 'assistant/attempt'
    || event.type === 'request/context'
}
