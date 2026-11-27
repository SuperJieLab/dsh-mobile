/**
 * 绑定监听地址，失败就在退避后重来。
 *
 * 为什么必须重试：生产配置绑的是 **tailnet 地址**（`config.host` = 100.x.y.z），而
 * 「dsh 起来了」和「Tailscale 把这个地址挂到接口上」是两件独立的事。插件先跑起来时
 * `listen` 直接 `EADDRNOTAVAIL`，而 Node 不会自己再来一次 —— 一次失败就是
 * 「进程在跑、端口没人听」：手机侧看到的是一次 SOCKS 建连失败（`-1000 bad URL`），
 * 网关侧一条请求记录都没有，两边日志对不上。
 *
 * 地址会**来回**：休眠唤醒、切网络、Tailscale 重连都会让它短暂消失，所以这里不是
 * 「等一会儿再试一次」，而是退避到上限之后一直试下去；只在插件卸载时停。
 *
 * 不降级成 `0.0.0.0`：绑到具体地址正是为了「虚拟网外不可达」（`index.test.ts` 有一条
 * 用例钉这件事）。悄悄扩大暴露面比不服务更坏。
 */
import type { Server } from 'node:net'

export interface BindOptions {
  port: number
  host: string
  /** 第一次重试前等多久，之后翻倍。 */
  baseDelayMs?: number
  /** 退避上限。到顶之后按这个间隔一直试。 */
  maxDelayMs?: number
  /** 绑定成功。参数是试到第几次才成功。 */
  onListening?: (attempts: number) => void
  /** 这一次失败，已经排了下一试。 */
  onRetry?: (error: NodeJS.ErrnoException, attempts: number, delayMs: number) => void
  /** 不可重试的错误（权限、地址形状）—— 再试也不会成。 */
  onGiveUp?: (error: NodeJS.ErrnoException, attempts: number) => void
  /** 已经在听之后的错误：那是运行期故障，与绑定无关。 */
  onFailureAfterListening?: (error: NodeJS.ErrnoException) => void
  schedule?: (run: () => void, delayMs: number) => unknown
  cancel?: (handle: unknown) => void
}

/** 这两种是「地址或端口暂时不可用」，等一会儿可能就好了。 */
const RETRYABLE = new Set(['EADDRNOTAVAIL', 'EADDRINUSE'])

/** 返回一个停止函数：清掉待跑的那一次，并摘掉监听。 */
export function bindWithRetry(server: Server, options: BindOptions): () => void {
  const base = options.baseDelayMs ?? 500
  const max = options.maxDelayMs ?? 10_000
  const schedule = options.schedule ?? ((run, ms) => setTimeout(run, ms))
  const cancel = options.cancel ?? (handle => clearTimeout(handle as NodeJS.Timeout))

  let attempts = 0
  let pending: unknown
  let stopped = false

  const attempt = () => {
    pending = undefined
    if (stopped) return
    attempts += 1
    server.listen(options.port, options.host)
  }

  const onError = (error: NodeJS.ErrnoException) => {
    if (stopped) return
    // 已经在听之后的错误不是绑定失败。重来会把一个已经在服务的端口关掉。
    if (server.listening) {
      options.onFailureAfterListening?.(error)
      return
    }
    if (!RETRYABLE.has(error.code ?? '')) {
      options.onGiveUp?.(error, attempts)
      return
    }
    const delayMs = Math.min(max, base * 2 ** (attempts - 1))
    options.onRetry?.(error, attempts, delayMs)
    pending = schedule(attempt, delayMs)
  }

  const onListening = () => {
    if (stopped) return
    options.onListening?.(attempts)
  }

  server.on('error', onError)
  server.on('listening', onListening)
  attempt()

  return () => {
    stopped = true
    if (pending !== undefined) {
      cancel(pending)
      pending = undefined
    }
    server.off('error', onError)
    server.off('listening', onListening)
  }
}
