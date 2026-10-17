/**
 * 一帧出站：编码、写出去、记一条 perf。
 *
 * 这是**帧**的出站口：编码 + 写 + perf。握手字节（101 / 404 / 401 / 400）与心跳
 * ping 不经这里 —— 它们不是 mux 帧，写它们的地方也不该知道帧形状。
 *
 * 它**没有自己的生命周期** —— 写失败（socket 已销毁）就静默跳过，那道判断属于
 * 调用方那条连接的收尾。它也没有状态：给它一帧、给它一个 socket，它写完就走。
 *
 * 它单列成一个文件，是因为连接层与流层都要它，而它的变化原因（编码格式、perf 字段、
 * 写策略）与那两份生命周期都不同。放进任一层，另一层就得反向依赖它 ——
 * 那正是 `remote/` 无环这条判据要防的事。
 */

import type { Duplex } from 'node:stream'
import { encodeServerFrame, type MuxServerFrame } from '../wire/mux.ts'
import { encodeTextFrame } from './frames.ts'
import { LogModule, perfNow, perfRecord } from '../log.ts'

/**
 * 一条帧过 send 边界时携带的计时上下文 —— 泵在循环里
 * 取 gwRecv（上游帧到达），send 在写出前补 gwSend 与字节数，合成一条 gw
 * 记录。窗口重放（opening）与事件帧同占这一段，故两者都走这条路：
 * opening 是单帧尺寸的最大来源，漏记它等于把要测的那条漏掉。
 * 缺的字段（seq / evTime / events）原样缺席，不填默认值。
 */
export interface PerfContext {
  readonly sessionId: string
  /** 帧的子类 —— 判读按它，不按「`seq` 缺席」（缺席当判据是脆的）。 */
  readonly kind: 'opening' | 'event'
  readonly seq?: number
  readonly evTime?: number
  /** 仅 opening：本条窗口携带的事件数，与 `bytes` 并读即得窗口形状。 */
  readonly events?: number
  /** 仅收窄过的 opening：被裁掉的轮数与事件数。未收窄时**缺席**，不填 0。 */
  readonly cutTurns?: number
  readonly cutEvents?: number
  /** 仅被拒绝的 opening：无帧可发，这里记原因（值为错误码）。 */
  readonly rejected?: string
  readonly gwRecv: number
}

/**
 * 一条 gw 记录的字段组装 —— 发送路径与拒绝路径共用它。拒绝时没有帧，但那条
 * 记录恰恰是「这个会话为什么打不开」的唯一答案，所以两处的字段集不能各写一遍。
 */
export function gwRecord(perf: PerfContext, gwSend: number, bytes: number): Record<string, unknown> {
  return {
    seg: 'gw',
    t: gwSend,
    sessionId: perf.sessionId,
    kind: perf.kind,
    ...(perf.seq === undefined ? {} : { seq: perf.seq }),
    ...(perf.evTime === undefined ? {} : { evTime: perf.evTime }),
    ...(perf.events === undefined ? {} : { events: perf.events }),
    ...(perf.cutTurns === undefined ? {} : { cutTurns: perf.cutTurns }),
    ...(perf.cutEvents === undefined ? {} : { cutEvents: perf.cutEvents }),
    ...(perf.rejected === undefined ? {} : { rejected: perf.rejected }),
    gwRecv: perf.gwRecv,
    gwSend,
    bytes,
  }
}

export function send(socket: Duplex, frame: MuxServerFrame, perf?: PerfContext): void {
  const frameBytes = encodeTextFrame(encodeServerFrame(frame))
  if (perf !== undefined) {
    // t2 段终点 = 写出时刻。t 与 gwSend 同值有意重复一次：消费方不必记
    // 「t 对 gw 记录意味着什么」这个约定。
    const gwSend = perfNow()
    perfRecord(LogModule.ws, gwRecord(perf, gwSend, frameBytes.length))
  }
  write(socket, frameBytes)
}

export function write(socket: Duplex, buffer: Buffer): void {
  if (socket.destroyed) return
  socket.write(buffer)
}
