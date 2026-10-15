/**
 * 反向窗口算术，被 `page`（rpc.ts）、follow 打开（mux.ts）与 follow 请求的
 * 窗口拼法（适配器 → remote/ws.ts）共享。
 *
 * `maxMessages` 是**目标**，不是承诺：调用方拿到的窗口**始于 turn 边界** ——
 * 一轮中间打开没有折叠头，只能平摊，回翻到该轮的打开处会把同一轮整体折起
 * （同内容、两形状）。目标的两倍即终止走查，够不到
 * 的边界因此不会无界撑大窗口。真实日志到不了 —— 四个会话的对齐代价
 * 为 5–18 条事件。
 */

/** 回走找 `turn/start` 时，窗口允许比目标宽多少。 */
const TURN_ALIGN_CEILING = 2

/**
 * 画页边界时算作一条消息的事件类型。这是画边界的规则，不是展示规则：
 * 客户端画得更少（注入的 `user/message` 有 `source.kind !== "user"`），
 * 窗口可以比画出的更宽，绝不会更窄。
 */
const MESSAGE_EVENT_TYPES: ReadonlySet<string> = new Set(['user/message', 'assistant/message'])

/** {@link pageWindow} 在日志 seq 不从 0 稠密时抛出。 */
export class LogNotDenseError extends Error {
  constructor(sessionId: string, index: number, seq: string) {
    super(`session "${sessionId}" log is not dense: index ${index} holds seq ${seq}`)
    this.name = 'LogNotDenseError'
  }
}

/** {@link pageWindow} 在 `beforeSeq` 指向日志末端之后时抛出。 */
export class CursorPastEndError extends Error {
  constructor(sessionId: string, beforeSeq: number, length: number) {
    super(`beforeSeq ${beforeSeq} is past the end of session "${sessionId}" (${length} events)`)
    this.name = 'CursorPastEndError'
  }
}

/** 一个反向窗口的几何 —— 见 {@link pageWindow}。 */
export interface PageWindow {
  /** 窗口首个 seq（客户端回翻页时的下一个 `beforeSeq`）。 */
  pageStart: number
  /** 窗口到达的排他上界。 */
  asOfSeq: number
  /** 窗口之前是否还有更旧的事件。 */
  hasOlder: boolean
  /** 窗口的事件，按 seq 排序。 */
  events: readonly WireEvent[]
}

/**
 * 在整条日志上取一个反向窗口 —— `page` 与 follow 打开共享的算术，两者因此
 * 不会漂移。按*消息数*约束，但按整个区间交付，因为被画 seq 的邻居常常不是
 * 消息（dev/contract/protocol.md §4.3）。**起点**回退到最近的 `turn/start`，
 * 因此绝不会在一轮中间打开 —— {@link TURN_ALIGN_CEILING} 说明原因与幅度。
 *
 * @throws {@link LogNotDenseError} 当 seq 不是 `0..n-1`：算术把位置当 seq 读，
 *   稠密是前置条件。两个调用方都以 `unreadable-session` 拒绝。
 */
import type { WireEvent } from './rpc.ts'

export function pageWindow(
  sessionId: string,
  events: readonly WireEvent[],
  beforeSeq: number | undefined,
  maxMessages: number,
): PageWindow {
  const lastIndex = events.findIndex((event, index) => event.seq !== index)
  if (lastIndex !== -1) {
    throw new LogNotDenseError(sessionId, lastIndex, String(events[lastIndex]?.seq))
  }

  const end = beforeSeq ?? events.length
  if (end > events.length) {
    // 与 `snapshot` 不同，此处的界是可知的 —— 整条日志在手 —— 末端之后的
    // 位置直接拒绝，不以空窗口作答。
    throw new CursorPastEndError(sessionId, end, events.length)
  }

  let start = 0
  let counted = 0
  for (let index = end - 1; index >= 0; index -= 1) {
    const event = events[index]
    // turn 边界优先于计数：目标达成后，继续走到*最近的* `turn/start`。
    // `turn/start` 不是消息，计数不受影响。
    if (event?.type === 'turn/start' && counted >= maxMessages) {
      start = index
      break
    }
    if (event === undefined || !MESSAGE_EVENT_TYPES.has(event.type)) continue
    counted += 1
    if (counted >= maxMessages * TURN_ALIGN_CEILING) {
      start = index
      break
    }
  }

  return { pageStart: start, asOfSeq: end, hasOlder: start > 0, events: events.slice(start, end) }
}

/**
 * 参考宿主对同一窗口规则的拼法，输入是 {@link pageWindow} 收到的同一目标。
 *
 * 参考把规则拆成「走到后可停的下限」与「必须停的上限」；我们由目标推出
 * 上限（{@link TURN_ALIGN_CEILING}）。两者都把走查封顶在目标的两倍，
 * follow 打开与 `page` 因此保持对齐。
 */
export function upstreamWindow(targetMessages: number): {
  maxMessages: number
  turnWindow: { minMessages: number; minTurns: number }
} {
  return {
    maxMessages: targetMessages * TURN_ALIGN_CEILING,
    // 参考一遇到 turn 就计入，所以 `minTurns: 1` 意为「最近的边界优先」
    // —— 与我们的走查一致。
    turnWindow: { minMessages: targetMessages, minTurns: 1 },
  }
}

/** {@link fitOpeningToBytes} 的结果：收窄后的起点，或「连最小窗口都装不下」。 */
export type OpeningShrink =
  | { start: number; cutTurns: number; cutEvents: number }
  | { unshrinkable: true }

/**
 * 把一个已切好的窗口收窄到字节上界之内 —— {@link pageWindow} 之后的二次约束。
 * 起点相对 `window` 本身（下标 0 是 `pageWindow` 给出的起点）。
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
 * @param window - 窗口内的事件，下标 0 即当前起点。
 * @param cap - 最终**帧**的字节上界（不止事件：外壳与随行基线都算在内）。
 * @param frameBytesOf - 量尺：给定候选起点，算出那一帧的序列化字节数。由调用方
 *   注入，因为帧里还有事件之外的东西（外壳、占用、模型基线、瞬态基线），
 *   那些只有调用方知道 —— 纯函数不猜。
 */
export function fitOpeningToBytes(
  window: readonly WireEvent[],
  cap: number,
  frameBytesOf: (start: number) => number,
): OpeningShrink {
  // 空窗口没有可裁的东西（空会话的打开就是空窗口）—— 「没得裁」不是「装不下」，
  // 不能被拒绝路径吞掉。
  if (window.length === 0) return { start: 0, cutTurns: 0, cutEvents: 0 }

  const turnStarts = window.flatMap((event, index) => (event.type === 'turn/start' ? [index] : []))
  // 候选起点：**0 永远在列**（「本来就装得下」是最该被选中的那一支），加上窗口内各
  // `turn/start`。窗口起点**不保证**落在轮边界上 —— 窗口是整份日志、或对齐目标在首个
  // `turn` 之前就到了，都会让 index 0 不是 `turn/start`。少了 0，装得下也会被裁到第一个
  // 轮边界上（真机：`1253711 bytes (fixed 542 + events 1253169)` 的帧在 4 MiB 上界下被报
  // `narrowed by 4 events / 0 turns`，客户端首屏因此少 4 条）。
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
