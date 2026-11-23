/**
 * 「这条事件可能挪动了投影」的判定。
 *
 * 只有判定，没有值、没有形状：把投影值变成线上载荷的那一步归客户端（`UsageView` /
 * `PermissionState`），这一层只回答「要不要重读」。
 *
 * **两族触发源，一张表**：control 泵按会话推的是**所有**投影，所以凡是能改动其中任何一格
 * 的事件都得在这里出现。漏一类不会报错 —— 症状是「那一格在别的设备上变了，手机上不动」。
 *
 * - 用量：`assistant/message` 与 `assistant/attempt` 贡献一次采样；`request/context` 是
 *   `contextWindow` 的唯一来源。
 * - 权限：`permission/preset` 是切档的落地事件，`sandbox/mode` 与 `approval/policy` 是
 *   它连带写下的两个 knob —— 三者任一到达，`permissions.currentValue` 都可能变了。
 *
 * ⚠️ 上游区分两种用量形状（`data.usage`，或 `data.stream` 的最后一个 chunk）；此处
 * 刻意不分：重读是内存内的同步读，无变化时什么也不发，区分形状只会多一条漏掉采样的路。
 */

export function usageIsTrigger(event: { type: string }): boolean {
  return event.type === 'assistant/message'
    || event.type === 'assistant/attempt'
    || event.type === 'request/context'
    || event.type === 'permission/preset'
    || event.type === 'sandbox/mode'
    || event.type === 'approval/policy'
}
