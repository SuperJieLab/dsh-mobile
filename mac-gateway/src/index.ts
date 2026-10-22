/**
 * mac-gateway —— dsh-mobile 的 Mac 侧 DSH 插件：只做装配。本文件把它们接起来，
 * 并管监听器的生命周期。目录按「改它要不要动手机端」分：
 *
 *   wire/      两端共守的形状与编解码 —— 改它，手机端必须同改
 *   ports/     装配边界：端口接口与上游失败的词汇
 *   protocol/  服务端协议判定：op 分派与处理器、窗口算术、用量投影、认证规则
 *   remote/    面向手机的传输（一元调用、流通道、RFC 成帧）
 *   upstream/  面向 DSH 宿主的适配
 *
 * 协议本身不在这个仓库里发布：它是两端共守的约定，读代码的人只需要知道
 * 「一条消息进、一条消息出」，具体的形状由 `wire/` 说清、op 与错误码由 `protocol/` 说清。
 *
 * 列表路径 (v2) 是零 I/O —— 头加宿主保留的投影，绝不读日志 —— 其四项
 * 服务在 `inject` 中声明：缺了它们 fiber 保持 pending，这对一个读不了
 * 会话的网关是正确的失败（列表是「当下的整表投影」，读不出就没有可说的）。
 *
 * 导入仅限 Node 内建与自有模块；cordis 只作类型引入 —— 运行期它是 dsh 安装树里的
 * 那一份（裸 specifier 在本仓库的安装树之外解析不到），本仓库 devDependency 里的
 * 同版那一个只供 `npm run typecheck`。
 */
import { DEFAULT_LIMITS, type Limits } from './protocol/rpc.ts'
import type { SessionPort } from './ports/session.ts'
import { createSessionPort, type PersistenceLike } from './upstream/sessions.ts'
import { attachStreamHandler } from './remote/server.ts'
import { createRpcListener } from './remote/http.ts'
import { CredentialVault, DEFAULT_CREDENTIALS_PATH } from './remote/credentials.ts'
import { broadcasterOver, commandChannelOver, gatewayOver, listSourceOver, modelChannelOver, modelSelectionSourceOver, streamSourceOver, writePortOver, type HostContext } from './upstream/faces.ts'
import { ApprovalRelay } from './upstream/write.ts'
import { ForwardedEvents } from './upstream/remote-events.ts'
import { createLogger, LogModule, startResourceSampler } from './log.ts'

const log = createLogger(LogModule.main)

/** dsh 诊断用的展示元数据。 */
export const name = 'mac-gateway'

/**
 * 插件启动前所需的服务；就绪之前 cordis 扣住 fiber（见模块注释）。
 */
export const inject = [
  // 读路径（snapshot / page）直取已存储的日志。
  'sessionPersistence',
  // 列表路径：记录（头 + 存活）、投影，以及在运行的东西。
  'sessionQuery',
  'sessionProjections',
  'sessionProjectionCache',
  'sessions',
  'agents',
  // follow 流：把控制器的 follow 泵到 WS 通道。
  // 仅 web-app bundle 提供。
  'sessionController',
  // approval 中继：网关的 `$events` 流是远程客户端接收并应答
  // approval waterfall 请求的通路。
  'typertGateway',
  // 中继的身份来源：进程内调用者只能经它取到开流所需的 Peer（R11）。
  'connection',
]

/** 插件配置，由所属 patch 行提供。 */
export interface Config {
  /** 绑定地址。`0.0.0.0` 可达 LAN；`127.0.0.1` 仅回环。 @default '0.0.0.0' */
  host?: string
  /** 绑定端口。 @default 3081 */
  port?: number
  /** 一条 `snapshot` 应答至多携带的事件数。做成配置是为了让上限可被端到端
   * 观测（`snapshot` 的窗口按消息数切，上限可被端到端量到）。 @default 500 */
  maxDeltaEvents?: number
  /** 一条应答 `events` 序列化尺寸的软上限，字节。 @default 1048576 */
  maxDeltaBytes?: number
  /** follow 打开单帧的字节上界，字节（R9 期1）。与上两个同理做成配置：调到
   * 极小值就能看见收窄路径真的发生。 @default 4194304 */
  maxOpeningBytes?: number
  /** 凭据文件位置；可覆盖，让装配冒烟测试绝不碰真实 home。
   * @default '~/.dsh/dsh-mobile/credentials.json' */
  credentialsPath?: string
  /** 用该 device token 预配对保险库（仅测试）—— 生产配对走配对码。 */
  deviceTokenSeed?: string
}

/**
 * 配置 → 应答上限。缺省项回退到 {@link DEFAULT_LIMITS}。抽成纯函数是为了让
 * 「配置里的值真的落到了上限上」有一条可断言的路径 —— `apply` 本身依赖宿主
 * 上下文，测它等于测整个运行时。
 */
export function resolveLimits(config: Config): Limits {
  return {
    maxDeltaEvents: config.maxDeltaEvents ?? DEFAULT_LIMITS.maxDeltaEvents,
    maxDeltaBytes: config.maxDeltaBytes ?? DEFAULT_LIMITS.maxDeltaBytes,
    maxOpeningBytes: config.maxOpeningBytes ?? DEFAULT_LIMITS.maxOpeningBytes,
  }
}

/** 全接口绑定的兜底值；生产经 config.host 改绑 tailnet 地址（100.64.0.1）。 */
const DEFAULT_HOST = '0.0.0.0'

/** 刻意不用 3080 —— 那是 dsh web profile 自己的端口。 */
const DEFAULT_PORT = 3081

/**
 * Cordis 以插件上下文和其树行中的配置调用本函数。host 与 port 是配置而非
 * 常量，切换可达性方案因此只是补一行 patch —— 可逆性主张要求绑定
 * 地址不被编译进去。
 */
export function apply(ctx: HostContext, config: Config = {}): void {
  const host = config.host ?? DEFAULT_HOST
  const port = config.port ?? DEFAULT_PORT
  const sessionPort: SessionPort = createSessionPort(
    ctx.sessionPersistence as unknown as PersistenceLike,
    listSourceOver(ctx),
    modelSelectionSourceOver(ctx),
  )
  // 上限是配置而非常量：它们存在的意义就是被调低直到分块读（以及收窄）
  // 可观测，这正是它们的验证方式。
  const limits = resolveLimits(config)

  // 保险库持有三张票（M4 §4.2）。
  // `pair` / `refresh` 绕过闸门 —— 它们自带凭据。
  const vault = new CredentialVault(config.credentialsPath ?? DEFAULT_CREDENTIALS_PATH)
  if (config.deviceTokenSeed !== undefined) {
    // 仅测试：不走配对码流程直接预配对。
    vault.seedDeviceToken(config.deviceTokenSeed)
  }
  log.info(`pairing code (valid 10 min, one-shot): ${vault.pairingCode()}`)

  // 写通道：上游 `$events` 流由 `ForwardedEvents` 持有（进程一份身份），中继订阅它
  // 把 `approval-answer` 桥接回去（宿主侧 waterfall 监听器收不到远程应答 —— api-remotes
  // 会把它们挂起，直到有远程客户端开口）；泵经控制器自己的门转发 `session-prompt`
  // （M5 §四）。手机侧的事件流是同一个源的第二类订阅者，不开第二条身份。
  const relayLifetime = new AbortController()
  const approvalFace = broadcasterOver()
  const gatewayFace = gatewayOver(ctx)
  const forwardedEvents = new ForwardedEvents(gatewayFace)
  const relay = new ApprovalRelay(forwardedEvents, gatewayFace, approvalFace, relayLifetime.signal)
  forwardedEvents.start(relayLifetime.signal)
  const writePort = writePortOver(ctx, relay)
  // 模型通道：声明式 face 调用中继与泵所用的同一控制器；服务缺席
  // 必须在装配时说清，而不是第一次点击时。
  const modelPort = modelChannelOver(ctx)
  // 命令通道：手机发的是一整行文本，宿主自己解析。与模型通道不同 —— 命令服务不在
  // `inject` 里（它是扩展，缺席不该让整个网关 pending），所以端口在第一次调用时才取
  // 那份服务；取不到就由协议层折成 `internal-error`。
  const commandPort = commandChannelOver(ctx)

  log.info('plugin loaded — auth on both channels, write + model channels on, command channel on demand')

  ctx.effect(() => {
    const server = createRpcListener({ sessionPort, limits, vault, writePort, modelPort, commandPort })

    // 流通道与监听器共享：同端口，`POST /rpc` 走单向调用，`/rpc/stream`
    // 升级与其他请求同一闸门：无有效 access token，就没有 101。
    const broadcaster = attachStreamHandler(server, streamSourceOver(ctx), vault, {
      // 打开帧的字节上界与 HTTP 路径的上限同源（同一个 `limits`）—— 两端各自
      // 记一个数才是口径不一致的来源。
      openingCapBytes: limits.maxOpeningBytes,
      // `{op:'events'}` 的流订阅这份源：身份是网关进程的，流是这条连接的。
      events: forwardedEvents,
      // 新接入的手机先拿到对账帧（所有挂起问题的 id），再逐条重放 ——
      // 它因此可以丢掉那些在其离线期间 `cancel` 已触发的转发卡片：
      // 缺席的 id 是权威的。帧序列由中继给出：它才是知道「还挂着什么」的那一层，
      // 装配层拼帧会让同一份形状在这里与 `write.ts` 各长一遍。
      onClientConnected: (send) => {
        for (const frame of relay.replayFrames()) send(frame)
      },
    })
    approvalFace.connect((frame) => broadcaster.broadcast(frame as Parameters<typeof broadcaster.broadcast>[0]))

    // 资源采样（R8 期1 链路 B）：5s 一条 res 记录 —— 事件循环是 dsh 全进程
    // 共享面，读数只做趋势；debug 级默认静默，采集时 DSH_LOG_DEBUG=1。
    const stopSampler = startResourceSampler({
      intervalMs: 5_000,
      module: LogModule.main,
      clientCount: () => broadcaster.clientCount(),
    })

    // 用我们的 logger（底层是 console）而非 ctx.logger：非 TTY 运行中
    // `ctx.logger.info` 什么也不输出（dsh 自己的启动行同样如此），绑定
    // 失败不可见比日志不合惯例更糟；TTY 门控未验证
    // （M0 §5.1）。
    server.on('error', (error) => {
      log.error(`listener error: ${String(error)}`)
    })

    server.listen(port, host, () => {
      log.info(`listening on http://${host}:${port}`)
    })

    return () => {
      relayLifetime.abort()
      stopSampler()
      // 自 Node 19 起，仅 close() 会让空闲 keep-alive socket 保持打开，
      // 端口因此在热重载期间仍被占用。
      server.closeAllConnections()
      server.close()
    }
  }, 'mac-gateway.listener')
}
