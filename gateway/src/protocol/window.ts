/**
 * 打开帧的字节收窄。**这是本文件唯一的判定。**
 *
 * 窗口本身不由网关切：`session/follow` 与 `session/page` 都把上游的请求原样转给宿主，
 * 「哪些记录算这一屏」于是只有一份规则。网关能施加的只有一条 —— WSS 一帧有字节上限，
 * 而上游的客户端没有这回事。
 *
 * 自己按 `maxMessages` 切一遍窗口，就是把宿主那份规则抄成第二份：它改规则时这里不会红，
 * 症状是「同一屏在 Web UI 与手机上长度不同」。
 */

import type { SessionRecord } from '../wire/rpc.ts'

/** {@link fitOpeningToBytes} 的结果：收窄后的起点，或「连最小窗口都装不下」。 */
export type OpeningShrink =
  | { start: number; cutTurns: number; cutEvents: number }
  | { unshrinkable: true }

/**
 * 把一个已切好的窗口收窄到字节上界之内 —— 装帧前的二次约束。
 * 起点相对 `window` 本身（下标 0 是传进来那个窗口的起点）。
 *
 * 它收的是**宿主交回来的记录**（打开帧那条路）：分页那一条没有字节上界这回事 ——
 * 它是 HTTP 应答，不占 WSS 的一帧。
 *
 * **两个口径各管一件事**：界由**字节**定（按内容单位切不保证有界 —— 按消息数切、
 * 按轮切都只是换位置撞墙），切点由**轮**定（起点落在轮次中段会让同一段过程在
 * 不同时刻形态不同，那是 B6 从源头修掉过的）。所以候选起点取窗口内的
 * `turn/start`，从最早试到最晚，第一个装得下的就是答案 —— 它同时是「装下最多」
 * 的那个。全都装不下 = 最后一轮自己就超界，此时**拒绝**而不是把一轮截成半截。
 *
 * 窗口内一个 `turn/start` 都没有时（起点本就不在轮边界的退化情形），退回按字节
 * 切：那种窗口本身极小，收窄通常不会触发，此处只需给出确定结果。
 *
 * @param window - 宿主交回来的记录，下标 0 即当前起点。
 * @param cap - 最终**帧**的字节上界（不止记录：外壳与随行基线都算在内）。
 * @param frameBytesOf - 量尺：给定候选起点，算出那一帧的序列化字节数。由调用方
 *   注入，因为帧里还有记录之外的东西（外壳、头部、投影基线、未定稿基线），
 *   那些只有调用方知道 —— 纯函数不猜。
 */
export function fitOpeningToBytes(
  window: readonly SessionRecord[],
  cap: number,
  frameBytesOf: (start: number) => number,
): OpeningShrink {
  // 空窗口没有可裁的东西（空会话的打开就是空窗口）—— 「没得裁」不是「装不下」，
  // 不能被拒绝路径吞掉。
  if (window.length === 0) return { start: 0, cutTurns: 0, cutEvents: 0 }

  // 记录外面那层 `{type:'event'}` 是线上的判别字段，轮边界看的是**里面那个事件**的
  // 类型 —— 看外层的话每一格都是 `'event'`，候选集只剩 0。
  const turnStarts = window.flatMap((record, index) => (record.event.type === 'turn/start' ? [index] : []))
  // 候选起点：**0 永远在列**（「本来就装得下」是最该被选中的那一支），加上窗口内各
  // `turn/start`。窗口起点**不保证**落在轮边界上 —— 窗口是整份日志、或对齐目标在首个
  // `turn` 之前就到了，都会让 index 0 不是 `turn/start`。少了 0，装得下也会被裁到第一个
  // 轮边界上，于是装得下也被裁掉开头几条 —— 客户端首屏因此缺内容，而日志里只留一行
  // 「narrowed by N events / 0 turns」，看不出是这里选错了候选。
  const candidates = turnStarts.length === 0
    ? [...window.keys()] // 一个轮边界都没有（退化窗口）：按字节切
    : [0, ...turnStarts.filter(index => index !== 0)]

  for (const start of candidates) {
    if (frameBytesOf(start) > cap) continue
    return {
      start,
      cutTurns: turnStarts.filter(index => index < start).length,
      cutEvents: start,
    }
  }
  return { unshrinkable: true }
}
