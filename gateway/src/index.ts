/**
 * dsh-mobile-gateway —— dsh-mobile 的 Mac 侧 DSH 插件：只做装配。本文件把它们接起来，
 * 并管监听器的生命周期。目录按「改它要不要动手机端」分：
 *
 *   wire/      两端共守的形状与编解码 —— 改它，手机端必须同改
 *   ports/     装配边界：端口接口与上游失败的词汇
 *   protocol/  服务端协议判定：op 分派与处理器、用量投影、认证规则
 *   remote/    面向手机的传输（一元调用、流通道、RFC 成帧）
 *   upstream/  面向 DSH 宿主的适配
 *
 * 协议本身不在这个仓库里发布：它是两端共守的约定，读代码的人只需要知道
 * 「一条消息进、一条消息出」，具体的形状由 `wire/` 说清、op 与错误码由 `protocol/` 说清。
 *
 * 列表路径不读日志：它转发宿主的 `session/list`，网关不再自己拼行。投影与存活
 * 会话表在 `inject` 中声明：缺了它们 fiber 保持 pending，这对一个读不了会话的
 * 网关是正确的失败（control 流的基线与模型基线都取自它们）。
 *
 * 导入仅限 Node 内建与自有模块；cordis 只作类型引入 —— 运行期它是 dsh 安装树里的
 * 那一份（裸 specifier 在本仓库的安装树之外解析不到），本仓库 devDependency 里的
 * 同版那一个只供 `npm run typecheck`。
 */
import { DEFAULT_LIMITS, type Limits } from './protocol/rpc.ts'
import type { SessionPort } from './ports/session.ts'
import { attachStreamHandler } from './remote/server.ts'
import { createRpcListener } from './remote/http.ts'
import { CredentialVault, DEFAULT_CREDENTIALS_PATH } from './remote/credentials.ts'
import { IdentityRegistry } from './remote/identity-registry.ts'
import { AuditLog, defaultAuditDirectory } from './audit.ts'
import { Metrics } from './metrics.ts'
import { checkHostVersion, hostVersionOf } from './host-version.ts'
import { commandChannelOver, gatewayOver, modelChannelOver, permissionChannelOver, sessionListFace, sessionPageFace, streamSourceOver, workspacePortOver, writePortOver, type HostContext } from './upstream/faces.ts'
import { directoryListingOver } from './upstream/directory-listing.ts'
import { ApprovalRelay } from './upstream/write.ts'
import { ForwardedEvents } from './upstream/remote-events.ts'
import { createLogger, LogModule, startResourceSampler } from './log.ts'

const log = createLogger(LogModule.main)

/** dsh 诊断用的展示元数据。 */
export const name = 'dsh-mobile-gateway'

/**
 * 插件启动前所需的服务；就绪之前 cordis 扣住 fiber（见模块注释）。
 */
export const inject = [
  // 会话投影与存活会话表：control 流的基线与模型基线取自它们。
  // 列表**不**在这里 —— 它转发宿主的 `session/list`（`sessionListFace`），
  // 连 `sessionQuery` 都不必注入：转发之后网关不再自己拼行。
  'sessionProjections',
  'sessions',
  'agents',
  // 工作空间的写面：把一条**已存在的**目录注册成组。「这一次是不是新建的」只有它回答。
  // 读面（组清单与归属）随 `workspace/follow` 流来，所以注册表本身不再需要注入。
  'workspaceController',
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
  /** follow 打开单帧的字节上界，字节。与上两个同理做成配置：调到
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
  return { maxOpeningBytes: config.maxOpeningBytes ?? DEFAULT_LIMITS.maxOpeningBytes }
}

/** 全接口绑定的兜底值；生产经 config.host 绑到 tailnet 接口地址（虚拟网外不可达）。 */
const DEFAULT_HOST = '0.0.0.0'

/** 刻意不用 3080 —— 那是 dsh web profile 自己的端口。 */
const DEFAULT_PORT = 3081

/**
 * Cordis 以插件上下文和其树行中的配置调用本函数。host 与 port 是配置而非
 * 常量，切换可达性方案因此只是补一行 patch —— 可逆性主张要求绑定
 * 地址不被编译进去。
 */
export function apply(ctx: HostContext, config: Config = {}): void {
  // 第一件事就报宿主版本：它决定「后面那些 API 还是不是那个形状」。
  // 只警告不阻止 —— 上游发个小版本就起不来，是比「可能漂了」更坏的交换。
  reportHostVersion()

  const host = config.host ?? DEFAULT_HOST
  const port = config.port ?? DEFAULT_PORT
  // 两条读路径都是**转发**：列表给 `session/list`，一页历史给 `session/page`。
  // 网关不读日志 —— 那份「哪些记录算一页」的规则归宿主，抄一份在它改规则时不会红。
  const sessionPort: SessionPort = {
    list: sessionListFace(ctx),
    page: sessionPageFace(ctx),
  }
  // 上限是配置而非常量：它们存在的意义就是被调低直到分块读（以及收窄）
  // 可观测，这正是它们的验证方式。
  const limits = resolveLimits(config)

  // 保险库持有三张票。
  // `pair` / `refresh` 绕过闸门 —— 它们自带凭据。
  const vault = new CredentialVault(config.credentialsPath ?? DEFAULT_CREDENTIALS_PATH)
  if (config.deviceTokenSeed !== undefined) {
    // 仅测试：不走配对码流程直接预配对。
    vault.seedDeviceToken(config.deviceTokenSeed)
  }
  log.info('pairing code issued (valid 10 min, one-shot)', { code: vault.pairingCode() })

  // 写通道：上游 `$events` 流由 `ForwardedEvents` 持有（进程一份身份），中继订阅它
  // 把 `approval-answer` 桥接回去（宿主侧 waterfall 监听器收不到远程应答 —— api-remotes
  // 会把它们挂起，直到有远程客户端开口）；泵经控制器自己的门转发 `session-prompt`。
  // 手机侧的事件流是同一个源的第二类订阅者，不开第二条身份。
  const relayLifetime = new AbortController()
  const gatewayFace = gatewayOver(ctx)
  const forwardedEvents = new ForwardedEvents(gatewayFace)
  const relay = new ApprovalRelay(forwardedEvents, gatewayFace, relayLifetime.signal)
  forwardedEvents.start(relayLifetime.signal)
  const writePort = writePortOver(ctx, relay)
  // 模型通道：声明式 face 调用中继与泵所用的同一控制器；服务缺席
  // 必须在装配时说清，而不是第一次点击时。
  const modelPort = modelChannelOver(ctx)
  // 命令通道：手机发的是一整行文本，宿主自己解析。与模型通道不同 —— 命令服务不在
  // `inject` 里（它是扩展，缺席不该让整个网关 pending），所以端口在第一次调用时才取
  // 那份服务；取不到就由协议层折成 `internal-error`。
  const commandPort = commandChannelOver(ctx)
  // 权限通道：只读目录 —— 当前值在 `permissions` 投影里，切档走 `/permission` 命令。
  // 与命令通道同形 —— 预设服务不在 `inject` 里，所以端口在第一次调用时才取；取不到
  // 不是错误，只是「这个装配没有权限格」，手机据此不画那一格。
  const permissionPort = permissionChannelOver(ctx)
  // 工作空间端口：建/删两条写面，读面（组清单与归属）另有一条 `workspace/follow` 流
  // （`workspacePortOver` 里的 `follow`），列表应答里没有归属。
  const workspacePort = workspacePortOver(ctx)

  log.info('plugin loaded — auth on both channels, write + model channels on, command + permission channels on demand')

  ctx.effect(() => {
    // 指标表：常驻计数器，读在 `GET /metrics`。与 `perf` 的分工是读的时机 ——
    // 那个要事先开 debug，这个随时能拉。
    const metrics = new Metrics()
    // 登记表**只 new 一次**，交给两条路：WS 升级（占名额）与一元闸门（判归属）。
    // 两处各 new 一个就永远 409 不到、也永远判不出主人 —— 409 与归属两条在真端口上钉住它。
    const registry = new IdentityRegistry()
    const server = createRpcListener({ sessionPort, vault, registry, writePort, modelPort, commandPort, workspacePort, directoryPort: directoryListingOver(), permissionPort, auditLog: new AuditLog(defaultAuditDirectory()), metrics })

    // 流通道与监听器共享：同端口，`POST /api/<命名空间>/<方法>` 走一元调用，`/api/remote.mux`
    // 升级与其他请求同一闸门：无有效 access token，就没有 101。
    const streamHandler = attachStreamHandler(server, streamSourceOver(ctx), vault, {
      registry,
      // 打开帧的字节上界：`limits` 现在只剩这一格（「一条应答多少事件」
      // 不是网关的事）。
      openingCapBytes: limits.maxOpeningBytes,
      // `$events` 流与审批中继订阅这份源：身份是网关进程的，流是这条连接的。
      events: forwardedEvents,
      // 组清单与归属的来源（`workspace/follow` 流）。与一元的建/删共用同一份端口 ——
      // 组流里出现的新组、删掉的组，都是宿主那一侧的事实，网关不另存一份。
      workspace: workspacePort,
      // 待答项随这条流走：开流时重放当前集合、之后随变化增量。它是审批唯一的
      // 投递通道 —— 连接建立时不再预先推一遍（那时还没有流编号可用）。
      approvals: relay,
    })

    // 资源采样：5s 一条 res 记录 —— 事件循环是 dsh 全进程
    // 共享面，读数只做趋势；debug 级默认静默，采集时 DSH_LOG_DEBUG=1。
    const stopSampler = startResourceSampler({
      intervalMs: 5_000,
      module: LogModule.main,
      clientCount: () => streamHandler.clientCount(),
      // 同一份读数也交给指标表：它读的是「最近一次采样」，不另开一份直方图。
      onSample: (sample) => metrics.updateRuntime(sample),
    })

    // 用我们的 logger（底层是 console）而非 ctx.logger：非 TTY 运行中
    // `ctx.logger.info` 什么也不输出（dsh 自己的启动行同样如此），绑定
    // 失败不可见比日志不合惯例更糟；TTY 门控未验证。
    server.on('error', (error) => {
      log.error('listener error', { error: String(error) })
    })

    server.listen(port, host, () => {
      log.info('listening', { host, port })
    })

    return () => {
      relayLifetime.abort()
      stopSampler()
      // 自 Node 19 起，仅 close() 会让空闲 keep-alive socket 保持打开，
      // 端口因此在热重载期间仍被占用。
      server.closeAllConnections()
      server.close()
    }
  }, 'dsh-mobile-gateway.listener')
}

/**
 * 报一句宿主版本。**只警告，不阻止** —— 理由见 `host-version.ts` 的模块注释。
 *
 * 放在 `apply` 第一行：它决定「后面那些 API 还是不是那个形状」，所以要在任何宿主
 * API 被调用之前说。晚说的话，报错会先以「某个方法不是函数」的形式出现。
 */
function reportHostVersion(): void {
  const check = checkHostVersion(hostVersionOf())
  switch (check.kind) {
    case 'match':
      log.info('host version matches', { version: check.version })
      break
    case 'differs':
      log.warn(
        'host version differs from the one this gateway was built against — upstream API may have drifted',
        { host: check.host, builtAgainst: check.builtAgainst },
      )
      break
    case 'unknown':
      // 读不到不是错：网关可能被测试装配加载，或入口形状变了。说一句，不吓人。
      log.info('host version unknown — could not read the host manifest')
      break
  }
}
