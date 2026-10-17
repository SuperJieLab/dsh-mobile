/**
 * 上游失败 → 协议码。判定层的事，不是传输的事：它依据的是**上游的错误语义**
 * （本运行时不解读的日志、按会话寻址时的 not-found），而传输只知道「刚才那次读抛了」。
 *
 * 这里有两个映射，规则**不同**，刻意不合并：
 *
 *   `streamErrorOf`  流通道：所读的一切都按会话寻址，所以 not-found 就是「会话不存在」
 *   `readErrorOf`    一元调用：`handle` 内部只区分「不可解读」与「其余」——
 *                    会话是否存在由端口返回 `undefined` 来表达，不走异常
 *
 * 合并成一个带参数的函数会让「哪条路径按会话寻址」变成调用方的一个布尔开关，
 * 那个开关迟早会传错，而错了的表现是**错误码错**（客户端据此决定重连还是重翻）。
 *
 * 它们住在判定层，因为它随上游的错误语义漂：上游多一个错误类、改一次 not-found
 * 的含义，这里就要跟着改，而传输层不该为上游的形状变化负责。
 */

import { describeError, isNotFound, isUnreadable } from '../ports/errors.ts'

/** 一个协议拒绝：码 + 给人看的句子。 */
export interface ProtocolRefusal {
  code: string
  message: string
}

/**
 * 流通道：一条 follow 流因上游失败而结束时，客户端收到的那条 error 帧。
 *
 * 三档：不可解读的日志是 `unreadable-session`（客户端无法展示这个会话）；
 * 按会话寻址时 not-found 是 `unknown-session`；其余是 `internal-error`。
 */
export function streamErrorOf(error: unknown): ProtocolRefusal {
  if (isUnreadable(error)) return { code: 'unreadable-session', message: describeError(error) }
  if (isNotFound(error)) return { code: 'unknown-session', message: describeError(error) }
  return { code: 'internal-error', message: describeError(error) }
}

/**
 * 一元调用：`handle` 的 catch 用它。两档 —— 会话是否存在不在这里判断（端口用
 * `undefined` 表达，不走异常），所以没有 not-found 那一档。
 */
export function readErrorOf(error: unknown): ProtocolRefusal {
  return isUnreadable(error)
    ? { code: 'unreadable-session', message: describeError(error) }
    : { code: 'internal-error', message: describeError(error) }
}
