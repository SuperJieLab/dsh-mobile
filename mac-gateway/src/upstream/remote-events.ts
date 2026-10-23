/**
 * 上游转发事件流的持有者。
 *
 * 网关是宿主 `$events` 流的一个远程客户端：开流、重连退避、客户端身份与代次都归
 * 这里，与「谁在消费这些事件」无关。今天有两类消费方：手机侧的事件流（`remote/stream.ts`
 * 的 `pumpEvents`）与审批中继（`approval/request` 的 waterfall，见 `write.ts`）；加一个
 * 消费方只是多一次 {@link ForwardedEvents.subscribe}，不必多开一条身份。
 *
 * **身份只有一份**。理由不是省资源：第二处 `openWireStream('$events')` 会让宿主把同一份
 * 审批在 N 个身份上各存一遍 —— 宿主的挂起问题投给**每一个** owner 客户端
 * （`api/gateway/src/index.ts` 的 waterfall 监听器），于是「答了但没落地」会变成 N 份
 * 各自不同的结论。
 *
 * 这一层只认识两件事：「上游来了一帧」与「源还在不在」。审批怎么答、手机的哪条流
 * 在听，都不归它管。
 */

import { describeError } from '../ports/errors.ts'
import type { ForwardedSink, ForwardedSource, UpstreamWireFrame } from '../ports/events.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.forwarded)

/**
 * 上游开流门的窄切面 —— 全仓只有本文件需要它。
 *
 * 返回类型照上游的样子留着 Promise 与非 Promise 两态：`openWireStream` 是异步的，
 * 直接迭代它的返回值会抛 `not async iterable`，所以调用点先 `await` 再迭代。
 */
export interface RemoteEventStreamLike {
  openWireStream(
    endpoint: string,
    payload: { args: Record<string, never> },
    signal: AbortSignal,
  ): AsyncIterable<UpstreamWireFrame> | Promise<AsyncIterable<UpstreamWireFrame>>
}

/** `$events` 流的重连退避，形状与 follow 客户端相同。 */
const RECONNECT_MIN_MS = 500
const RECONNECT_MAX_MS = 10_000

export class ForwardedEvents implements ForwardedSource {
  readonly #stream: RemoteEventStreamLike
  readonly #sinks = new Set<ForwardedSink>()
  #clientId: string | undefined
  /** 上游一共建立过几次源。代次只增不减：重连后从下一个数继续，跳过的那几代是真的发生过。 */
  #established = 0
  #abort: AbortController | undefined

  constructor(stream: RemoteEventStreamLike) {
    this.#stream = stream
  }

  /**
   * 打开 `$events` 流并维持它，直到 `lifetime` 中止（插件拆除）。
   * 绝不抛错；一代结束、封顶退避后下一代开始 —— 存活不是可选项，死掉的源会让
   * 手机的审批卡片静默清空、事件流从此只剩心跳。
   */
  start(lifetime: AbortSignal): void {
    void this.#run(lifetime)
  }

  /** 测试专用出口（生产 teardown 走 lifetime.abort()）。 */
  stop(): void {
    this.#abort?.abort()
  }

  /** 上游此刻是否有一个存活的客户端身份。 */
  get ready(): boolean {
    return this.#clientId !== undefined
  }

  /** 应答要带上的身份（上游按它找客户端）；没有存活身份时为 `undefined`。 */
  get clientId(): string | undefined {
    return this.#clientId
  }

  /** 源的代次；`undefined` = 此刻没有活的代次（消费方据此知道自己的基线是旧的）。 */
  get generation(): number | undefined {
    return this.#clientId === undefined ? undefined : this.#established
  }

  /**
   * 订阅源的一切通知；返回退订函数。
   *
   * 订阅**不补发**当前状态：需要「现在有没有代次」的消费方自己读 {@link generation}
   * —— 那是它开流时必须做的一次读取（开口帧不许等源），不该伪装成一个迟到的事件。
   */
  subscribe(sink: ForwardedSink): () => void {
    this.#sinks.add(sink)
    return () => {
      this.#sinks.delete(sink)
    }
  }

  async #run(lifetime: AbortSignal): Promise<void> {
    this.#abort = new AbortController()
    const signal = AbortSignal.any([this.#abort.signal, lifetime])
    let backoff = RECONNECT_MIN_MS
    while (!signal.aborted) {
      try {
        const stream = await this.#stream.openWireStream('$events', { args: {} }, signal)
        for await (const frame of stream) {
          if (signal.aborted) return
          if (frame.type === 'ready') {
            this.#clientId = frame.clientId
            this.#established += 1
            backoff = RECONNECT_MIN_MS
            log.info(`$events ready (clientId ${frame.clientId}, generation ${this.#established})`)
            this.#announceGeneration()
            continue
          }
          this.#announceFrame(frame)
        }
        if (signal.aborted) return
        log.warn('$events stream ended; reconnecting')
      } catch (error) {
        if (signal.aborted) return
        log.error(`$events stream failed: ${describeError(error)}; reconnecting`)
      }
      this.#loseSource()
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, backoff)
        signal.addEventListener('abort', () => { clearTimeout(timer); resolve() }, { once: true })
      })
      backoff = Math.min(backoff * 2, RECONNECT_MAX_MS)
    }
  }

  /**
   * 身份随流一起死掉：宿主会重投每个仍在等待的问题，消费方沿用旧集合会重放已消费
   * 的应答。代次同时作废 —— 「源不在了」不是「还是上一代」。
   */
  #loseSource(): void {
    this.#clientId = undefined
    this.#announceGeneration()
  }

  #announceGeneration(): void {
    for (const sink of this.#sinks) {
      this.#deliver(() => sink.generation(this.generation))
    }
  }

  #announceFrame(frame: UpstreamWireFrame): void {
    for (const sink of this.#sinks) {
      this.#deliver(() => sink.frame(frame))
    }
  }

  /**
   * 一个订阅者抛错不许让源换代：换代会让宿主重投全部待答问题、事件泵重发 `ready`，
   * 一个消费方的 bug 因此变成所有消费方的事故。降级成一行日志。
   */
  #deliver(hand: () => void): void {
    try {
      hand()
    } catch (error) {
      log.error(`a $events subscriber threw: ${describeError(error)}`)
    }
  }
}
