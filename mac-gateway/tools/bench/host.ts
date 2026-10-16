/**
 * 压测假宿主（R8 期2 链路 A）—— 造一个提供九面最小形状的宿主 ctx，让真插件
 * （`src/index.ts` 的 `apply`）在其上装配：装配层、HTTP 监听器、WS 泵、mux 编码、
 * 中继声明全部是真代码，只有事件的来源是假的（决定 1）。
 *
 * 九面清单即 `src/index.ts` 的 `inject`。cordis 对缺面的真实反应是**静默**扣住
 * fiber（表现为「起来了但没监听」），所以齐备断言必须在 `apply` 之前由本文件
 * 替它喊出来 —— 这是「依赖面在装配期探测形状与能力」（R11 决定）在工具侧的
 * 同一手法。
 *
 * 安装法沿用 `tests/index.test.ts` 的既有模式：`effect` 立即执行、随机高位端口、
 * 临时目录凭证 —— 扫参绝不污染真实的 `~/.dsh` 与凭证文件（决定 4）。
 */
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply } from '../../src/index.ts'

/** 假宿主必须提供的九个宿主服务名（与 `src/index.ts` 的 `inject` 同一张单）。 */
export const REQUIRED_FACES = [
  'sessionPersistence',
  'sessionQuery',
  'sessionProjections',
  'sessionProjectionCache',
  'sessions',
  'agents',
  'sessionController',
  'typertGateway',
  'connection',
] as const

/** 集合里缺了哪些面。纯函数：`undefined` / `null` 都算缺。 */
export function missingFaces(services: Record<string, unknown>): string[] {
  return REQUIRED_FACES.filter(name => services[name] === undefined || services[name] === null)
}

/** 一个空的 follow 源：打开给一个空日志快照，随后挂住直到取消。 */
const idleFollowController = {
  follow: async function* (_request: unknown, signal: AbortSignal) {
    yield { type: 'snapshot', cursor: -1, records: [], hasMore: false }
    while (!signal.aborted) await new Promise(resolve => setTimeout(resolve, 50))
  },
}

/**
 * 九面的默认最小形状：每个面只到「装配不炸、请求有答」的程度。
 * `typertGateway` 与 `connection` 复刻上游运行时的签名（`wireStream.open` 带
 * `peer` 且解引用它；`dispatchRpc` 同样先读 Peer）—— 假件逐字复刻上游签名
 * 的纪律在这里同样适用。压测真正要造事件的面（`sessionController`）由
 * `tools/bench/upstream.ts` 提供，经 `installBench` 覆盖。
 */
export function defaultBenchFaces(): Record<string, unknown> {
  return {
    // 读路径（snapshot / page）：空日志的会话句柄。
    sessionPersistence: {
      open: async () => ({
        read: async () => ({ events: [] }),
        close: async () => {},
      }),
    },
    // 列表路径的记录来源。
    sessionQuery: { listSessions: async () => [] },
    // 投影读数：缺席是诚实答案（无占用、无基线帧）。
    sessionProjections: { cachedSnapshot: () => undefined, snapshot: () => undefined },
    sessionProjectionCache: { cachedSnapshot: () => undefined, cachedPredecessorTitle: () => undefined },
    sessions: { get: () => undefined },
    agents: { get: () => undefined },
    sessionController: idleFollowController,
    // 中继的 `$events` 流与应答门（签名照抄 `tests/index.test.ts` 对运行时
    // 0.2.1-alpha 的复刻：peer 必需、先解引用 signal）。
    typertGateway: {
      wireStream: {
        async open(
          _endpoint: string,
          _payload: unknown,
          _uplink: AsyncIterable<unknown>,
          peer: { signal: AbortSignal },
          signal: AbortSignal,
        ) {
          void peer.signal.aborted
          return (async function* () {
            yield { type: 'ready', clientId: 'bench-upstream' }
            while (!signal.aborted) await new Promise(resolve => setTimeout(resolve, 50))
          })()
        },
      },
      async dispatchRpc(
        endpoint: string,
        payload: unknown,
        signal: AbortSignal,
        peer: { signal: AbortSignal },
      ) {
        void endpoint
        void payload
        void peer.signal.aborted
        AbortSignal.any([signal])
        return { ok: true, value: undefined }
      },
    },
    // 中继的身份来源（R11）：进程内 owner Peer。
    connection: {
      createPeer(values: { principal: { kind: string }; interactions?: string }) {
        return {
          principal: values.principal,
          interactions: values.interactions ?? 'answer',
          signal: new AbortController().signal,
        }
      },
    },
  }
}

export interface BenchInstall {
  /** 监听器实际绑定的端口（随机高位，互不竞争）。 */
  port: number
  credentialsPath: string
  /** 停采样器、关监听器、删临时凭证。 */
  teardown: () => void
}

/**
 * 在假宿主上装配真插件。缺面**高声失败**并点名缺哪些（H2）—— 不把
 * 「起来但没监听」留给扫参现场。随机高位端口落在 macOS 的临时端口段里，
 * 偶发与其他进程撞车：起不来就换端口重试（最多 5 次）——「起来了但没
 * 监听」在工具侧同样不可接受。
 */
export async function installBench(
  services: Record<string, unknown> = {},
  config: Record<string, unknown> = {},
): Promise<BenchInstall> {
  const faces = { ...defaultBenchFaces(), ...services }
  const missing = missingFaces(faces)
  if (missing.length > 0) {
    throw new Error(
      `bench host is missing host face(s): ${missing.join(', ')}`
        + ' — cordis would hold the assembly fiber silently, so the bench refuses to start',
    )
  }

  const cleanups: (() => void)[] = []
  const credentialsDir = mkdtempSync(join(tmpdir(), 'mac-gateway-bench-'))
  const credentialsPath = join(credentialsDir, 'credentials.json')

  let lastError: unknown
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const port = 55_000 + Math.floor(Math.random() * 1_500)
    apply(
      {
        effect: (fn: () => () => void) => { cleanups.push(fn()) },
        ...faces,
      } as never,
      { host: '127.0.0.1', port, credentialsPath, deviceTokenSeed: 'bench-device-token', ...config } as never,
    )
    if (await listenerUp(port, 2_000)) {
      return {
        port,
        credentialsPath,
        teardown: () => {
          for (const cleanup of [...cleanups].reverse()) cleanup()
          cleanups.length = 0
          rmSync(credentialsDir, { recursive: true, force: true })
        },
      }
    }
    lastError = new Error(`bench listener did not come up on port ${port} (attempt ${attempt + 1})`)
    // 换端口重来：先拆掉这一轮的监听器与采样器。
    for (const cleanup of [...cleanups].reverse()) cleanup()
    cleanups.length = 0
  }
  // 全部尝试失败：临时目录不留残留（收口审查 Minor 4）。
  rmSync(credentialsDir, { recursive: true, force: true })
  throw lastError
}

/** 轮询等监听器应答；等不到（如 EADDRINUSE）返回 false，由调用方换端口。 */
async function listenerUp(port: number, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/`)
      if (response.ok) return true
    } catch { /* 还没起来，继续等 */ }
    await new Promise(resolve => setTimeout(resolve, 50))
  }
  return false
}
