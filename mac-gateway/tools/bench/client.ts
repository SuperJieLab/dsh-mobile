/**
 * 脚本客户端（R8 期2 链路 B）—— 跑曲线用的可脚本化客户端：走**真** WebSocket、
 * 按 mux 契约成帧（帧形状引自 `wire/mux.ts`，不另写协议），产出与 iOS
 * 同字段的 `dev` 记录，并把「事件进入镜像」做成最简 fold 等价物。
 *
 * 决定 4 的代价边界（写进产物时必须带上）：脚本与网关**同机**，它的传输段只含
 * 环回；fold 是**再实现**（只保证等价的「事件进入镜像」），不是真 App 的解码
 * 路径 —— 曲线点因此带 `client=script` 标签，绝不与真机轮混进同一条曲线。
 *
 * 不做自动重连：负载点有效性判据之一就是「一轮内无重连」（决定 6），`gen`
 * 在一轮内恒为 1 是它的脚本侧形态 —— 连接断了对这条 run 就是失败，不遮掩。
 */
import { randomUUID } from 'node:crypto'
import { perfNow } from '../../src/log.ts'

/**
 * 一条 dev 记录 —— 与 iOS `FollowClient` 产出的字段集逐字段对齐（期1 契约）。
 *
 * 写成 `type` 而不是 `interface`：它是一条记录的**字面量形状**，没有可扩展的命名契约；
 * 而 `interface` 不参与「隐式 index signature」，于是赋不进 `PerfLike` 这类带索引签名的读面
 * —— 那会让「产物里装的是 perf 行」这条事实在类型上断掉。
 */
export type BenchDevRecord = {
  seg: 'dev'
  t: number
  sessionId: string
  seq: number
  kind: 'opening' | 'event'
  gen: number
  devRecv: number
  devApply: number
  bytes: number
}

export interface BenchClientOptions {
  port: number
  /** 走真 `refresh` op 换 access token 所用的设备票（假宿主预配对的种子）。 */
  deviceToken: string
  sessionId: string
  host?: string
}

/** 走真 HTTP 认证门换 access token（与 iPhone 同一条路：`refresh` op）。 */
export async function benchAccessToken(port: number, deviceToken: string, host = '127.0.0.1'): Promise<string> {
  const response = await fetch(`http://${host}:${port}/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ v: 2, op: 'refresh', deviceToken }),
  })
  if (!response.ok) throw new Error(`refresh refused: HTTP ${response.status}`)
  const body = await response.json() as { ok: boolean; accessToken?: string }
  if (!body.ok || body.accessToken === undefined) throw new Error('refresh did not mint an access token')
  return body.accessToken
}

interface Waiter {
  check: () => boolean
  resolve: () => void
}

export class BenchClient {
  private readonly options: Required<Pick<BenchClientOptions, 'port' | 'deviceToken' | 'sessionId'>> & { host: string }
  private readonly recordsStore: BenchDevRecord[] = []
  /** fold 等价物：实时事件逐条进镜像（opening 的窗口计入 opening 记录，不进这里）。 */
  private readonly mirror = new Map<number, unknown>()
  private error: { code: string; message: string } | undefined
  /** 连接层故障（区别于 error 帧）—— 中途断流要进 verdict，不能崩进程。 */
  private socketFailure: string | undefined
  /** 连接是否还开着（判据③「连接存活覆盖整个 run 窗口」的脚本侧形态）。 */
  private closedEarly = false
  private socket: WebSocket | undefined
  /**
   * 这条流的编号 —— 开流那一刻现造，与 iOS 同一条规则（编号不复用，重开换号）。
   * 脚本不重开，所以一轮里只有这一个；但它不是常量：编号里不读用途。
   */
  private streamId = ''
  private gen = 0
  private waiters: Waiter[] = []
  private closed = false

  constructor(options: BenchClientOptions) {
    this.options = { host: options.host ?? '127.0.0.1', ...options }
  }

  /** 连接 + 打开 follow 流。`gen` 随连接递增；一轮内它必须恒定。 */
  async start(): Promise<void> {
    const access = await benchAccessToken(this.options.port, this.options.deviceToken, this.options.host)
    const url = `ws://${this.options.host}:${this.options.port}/rpc/stream`
    // 第二参在运行时是 undici 的 init：`headers` 进握手请求（实测 `req.headers.authorization`
    // 拿得到它的值，Node 22.22），而 `@types/node` 只声明协议名 `string | string[]`。
    // 类型落后于运行时，故在此断言一次 —— 网关的 WS 闸门就要这一个头。
    const socket = new WebSocket(url, { headers: { authorization: `Bearer ${access}` } } as unknown as string[])
    this.socket = socket
    // 超时在 Promise 的 executor 里挂：函数体内那个 `reject` 只在 executor 里存在，
    // 挂在外面会在超时时抛 `ReferenceError` 而不是让这一轮失败（收口审查发现）。
    await new Promise<void>((resolve, reject) => {
      const upgradeTimeout = setTimeout(() => reject(new Error('bench client upgrade timed out')), 5_000)
      socket.addEventListener('open', () => { clearTimeout(upgradeTimeout); resolve() }, { once: true })
      socket.addEventListener('error', () => {
        clearTimeout(upgradeTimeout)
        reject(new Error('bench client upgrade failed'))
      }, { once: true })
    })
    this.gen += 1
    // 持久的连接层监听：中途断流/报错记下来进 verdict（收口审查 Major 3）——
    // 没有它，error 事件是未处理异常，压测进程当场崩而不是落进产物。
    socket.addEventListener('error', () => { this.socketFailure = 'socket error' })
    socket.addEventListener('close', () => { this.closedEarly = true })
    socket.addEventListener('message', event => this.onMessage(String((event as { data: unknown }).data)))
    this.streamId = randomUUID()
    socket.send(JSON.stringify({
      type: 'open',
      streamId: this.streamId,
      payload: { op: 'follow', sessionId: this.options.sessionId },
    }))
  }

  /** 等到再收到 n 条事件记录（或超时）。 */
  async waitForEvents(n: number, timeoutMs: number): Promise<void> {
    const target = this.recordsStore.filter(record => record.kind === 'event').length + n
    await this.waitFor(() => this.recordsStore.filter(record => record.kind === 'event').length >= target, timeoutMs,
      `waiting for ${n} more events`)
  }

  /** 等一条 error 帧（被拒的打开走这条路，而不是死寂）。 */
  async waitForError(timeoutMs: number): Promise<void> {
    await this.waitFor(() => this.error !== undefined, timeoutMs, 'waiting for an error frame')
  }

  records(): readonly BenchDevRecord[] {
    return this.recordsStore
  }

  /** fold 等价物的镜像内容：已应用的实时事件 seq（升序由调用方排）。 */
  mirrorSeqs(): number[] {
    return [...this.mirror.keys()]
  }

  lastError(): { code: string; message: string } | undefined {
    return this.error
  }

  /** 连接层是否中途出过故障（socket error / 提前关闭）—— verdict 判定③用。
   * 主动 `close()` 之后的关闭是自己走的，不算。 */
  connectionBroke(): string | undefined {
    if (this.closed) return this.socketFailure
    if (this.socketFailure !== undefined) return this.socketFailure
    return this.closedEarly ? 'socket closed before the run ended' : undefined
  }

  /** 取消流并关闭连接（留出 close 传播的时间）。 */
  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    this.socket?.send(JSON.stringify({ type: 'cancel', streamId: this.streamId }))
    this.socket?.close()
    await new Promise(resolve => setTimeout(resolve, 30))
  }

  private waitFor(check: () => boolean, timeoutMs: number, what: string): Promise<void> {
    if (check()) return Promise.resolve()
    return new Promise<void>((resolve, reject) => {
      const waiter: Waiter = { check, resolve }
      this.waiters.push(waiter)
      setTimeout(() => {
        const index = this.waiters.indexOf(waiter)
        if (index >= 0) this.waiters.splice(index, 1)
        reject(new Error(`bench client timed out ${what}; records=${this.recordsStore.length}, error=${JSON.stringify(this.error)}`))
      }, timeoutMs)
    })
  }

  private settle(): void {
    for (const waiter of [...this.waiters]) {
      if (waiter.check()) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1)
        waiter.resolve()
      }
    }
  }

  private onMessage(text: string): void {
    let frame: Record<string, unknown>
    try {
      frame = JSON.parse(text) as Record<string, unknown>
    } catch {
      return
    }
    if (frame.type !== 'item') {
      if (frame.type === 'error') {
        const payload = frame.payload as { code?: string; message?: string } | undefined
        this.error = { code: payload?.code ?? 'internal-error', message: payload?.message ?? '' }
        this.settle()
      }
      return
    }

    const payload = frame.payload as Record<string, unknown> | undefined
    if (payload === undefined) return

    // 打开帧：sessionId + cursor + events 三件齐（判读与 iOS `FollowClient` 同一形状）。
    if (payload['sessionId'] !== undefined && payload['cursor'] !== undefined && payload['events'] !== undefined) {
      const devRecv = perfNow()
      // fold 等价物（opening 半）：窗口事件进镜像 —— 应用是同步的，返回即 fold 完成。
      const events = payload['events'] as Record<string, unknown>[]
      for (const windowEvent of events) this.mirror.set(windowEvent.seq as number, windowEvent)
      this.recordsStore.push({
        seg: 'dev',
        t: perfNow(),
        sessionId: payload['sessionId'] as string,
        seq: payload['cursor'] as number,
        kind: 'opening',
        gen: this.gen,
        devRecv,
        devApply: perfNow(),
        bytes: Buffer.byteLength(text, 'utf8'),
      })
      this.settle()
      return
    }

    // 事件帧：payload 本体就是事件（与 gw 记录对齐的那一个 seq）。
    if (payload['type'] !== undefined && payload['seq'] !== undefined) {
      const devRecv = perfNow()
      this.mirror.set(payload['seq'] as number, payload)
      this.recordsStore.push({
        seg: 'dev',
        t: perfNow(),
        sessionId: this.options.sessionId,
        seq: payload['seq'] as number,
        kind: 'event',
        gen: this.gen,
        devRecv,
        devApply: perfNow(),
        bytes: Buffer.byteLength(text, 'utf8'),
      })
      this.settle()
    }
    // 其余（transient / usage / approval）不是曲线端点，逐帧不计时。
  }
}
