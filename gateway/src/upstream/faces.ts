/**
 * 网关眼中的 DSH 宿主切面：包括宿主真实类型迫使我们声明的全部窄接口
 * （`*Like`，它们在 dsh 安装目录之外无法解析），以及基于宿主服务构建网关侧
 * 端口的全部 `*Over(ctx)` 工厂。组装层（`index.ts`）只调用这些工厂。
 *
 * 这里的类型断言是有意的：每个服务只断言到消费方适配器声明的窄形状，
 * 不再多断。
 */
import type { Context } from '@deepseek-ai/cordis'
import { isNotFound, isRemoteError } from '../ports/errors.ts'
import type { WritePort } from '../ports/write.ts'
import type { ModelPort } from '../ports/model.ts'
import type { CommandPort } from '../ports/command.ts'
import type { SessionPort } from '../ports/session.ts'
import type { ModelCatalog, ModelSelection } from '../wire/model.ts'

import { createWorkspaceIn, deleteWorkspaceIn, type WorkspaceCreateFace, type WorkspaceDeleteFace } from './workspace.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import type { WorkspaceFollowFrame } from '../wire/workspace-stream.ts'
import type { FollowSource } from '../ports/follow.ts'
import { commandPortOver, type CommandsLike, type LiveAgentsLike } from './command.ts'
import { permissionPortOver } from './permission.ts'
import type { PermissionPort } from '../ports/permission.ts'
import type { PermissionCatalog } from '../wire/permission.ts'
import { callThrough, openStreamThrough, parameterNamesOf, signatureNoteOf, type PeerScopeLike } from './call-through.ts'
import { ApprovalRelay, pumpPrompt, type PromptControllerLike, type RemoteEventAnswerLike } from './write.ts'
import type { RemoteEventStreamLike } from './remote-events.ts'
import type { UpstreamWireFrame } from '../ports/events.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.faces)

/**
 * 宿主上下文。`Context` 声明的只有 cordis 的核心服务；插件服务的名字是**运行期**才有
 * 的事实（就是 `index.ts` 的 `inject` 那张单），所以这里把「服务名可读」写进类型：
 * 读出来一律 `unknown`，由各消费点窄化成自己的 `*Like`。少了这一层，每读一个服务都要
 * 先绕一次 `as unknown as` —— 断言本身仍在，但它现在只表达「窄到什么」，不再兼职
 * 「这个属性存不存在」。
 *
 * ⚠️ 这个「可读」只对 **`inject` 里那几名**成立，类型看不出来：cordis 对未注入的服务
 * 属性一读就抛（`cannot get property "x" without inject`），而 `apply` 在启动时跑 ——
 * 一次越界读就让整个插件起不来。不注入的服务一律经 `ctx.reflect.get(name)` 取，
 * 它是那条路由上唯一不要求 inject 的入口。
 */
export type HostContext = Context & Record<string, unknown>

/**
 * 列表路径：**转发宿主的 `session/list`**，不自己拼行。
 *
 * 这一层只做一件事 —— 把宿主的方法递给端口。排序、可见性、访问过滤、投影块都在
 * 宿主那一侧（`SessionController.list` 已经做过），我们再算一遍就是第二份形状：
 * 上游每加一格字段，那一份就漏一格，而漏掉不会编译失败。
 */
export function sessionListFace(ctx: HostContext): SessionPort['list'] {
  return async (request, signal) => {
    const controller = ctx.sessionController as unknown as Partial<SessionListControllerLike>
    if (typeof controller.list !== 'function') {
      throw new Error('sessionController has no list face — session/list cannot be served')
    }
    return await controller.list(request, signal)
  }
}

/** 本模块用到的 `ctx.sessionController.list` 部分。 */
interface SessionListControllerLike {
  list(request: Readonly<Record<string, unknown>>, signal: AbortSignal): Promise<unknown>
}

/**
 * 一页历史：**直呼宿主的 `sessionController.page(request, signal)`**，入参与应答都不动。
 *
 * 上一版网关自己按 `maxMessages` 切窗口（`protocol/window.ts` 的 `pageWindow`），
 * 等于把宿主的规则抄了一遍 —— 宿主改规则时网关不会红，症状是「同一屏在 Web UI 与
 * 手机上长度不同」。判据见 `tests/protocol/page-forward.test.ts`。
 *
 * 宿主没有这个切面时抛错（装配错误），由协议层折成 `internal-error`。
 */
export function sessionPageFace(ctx: HostContext): SessionPort['page'] {
  return async (request, signal) => {
    const controller = ctx.sessionController as unknown as Partial<SessionPageControllerLike>
    if (typeof controller.page !== 'function') {
      throw new Error('sessionController has no page face — session/page cannot be served')
    }
    return await controller.page(request, signal)
  }
}

/** 本模块用到的 `ctx.sessionController.page` 部分 —— 签名与运行时逐字一致。 */
interface SessionPageControllerLike {
  page(request: Readonly<Record<string, unknown>>, signal: AbortSignal): Promise<unknown>
}

/**
 * 工作空间端口：组流 + 两条写面。
 *
 * 组清单与归属只有一处来源 —— `workspace/follow` 的 `items[].sessionIds`。网关不再
 * 自己按目录比一遍（那份判据宿主已经做过），也不在 HTTP 上另开一条读。
 */
export function workspacePortOver(ctx: HostContext): WorkspacePort {
  const follow = workspaceFollowFace(ctx)
  return {
    ...follow === undefined ? {} : { follow },
    // 只转发：宿主按路径注册一个已存在的目录，标题由它从路径取。网关不建目录 ——
    // 手机传进来的路径必须是宿主上已经存在的那个（目录浏览器保证这一点）。
    create: async (path) =>
      await createWorkspaceIn(ctx.workspaceController as unknown as WorkspaceCreateFace, path),
    // 删除只转发：宿主那一行 `delete` 已经把「只解注册、保留目录与会话日志」写进了语义，
    // 我们唯一要补的是「删一个已经不在的算成功」（见 `deleteWorkspaceIn`）。
    delete: async (workspaceId) => {
      await deleteWorkspaceIn(ctx.workspaceController as unknown as WorkspaceDeleteFace, workspaceId)
    },
  }
}

/**
 * 组流的来源：**直呼宿主的 `workspaceController.follow(signal)`**，不加工。
 *
 * 七个帧形状就是线上形状（见 `wire/workspace-stream.ts`）—— 网关只做鉴权、帧化与
 * 取消。可见性过滤（`remoteAccess`）在宿主那一侧，所以这里不必也不该再筛一遍：
 * 筛两遍的后果是两份规则分叉，而分叉时手机与 Web UI 的组不一样。
 *
 * 宿主没有这个切面时返回 `undefined`：泵据此回一条 `internal-error`，而不是一条
 * 永远等不到基线的流（那会让整条连接在 45 秒后一起被判死）。
 */
export function workspaceFollowFace(
  ctx: HostContext,
): ((signal: AbortSignal) => AsyncIterable<WorkspaceFollowFrame>) | undefined {
  const controller = ctx.workspaceController as unknown as Partial<WorkspaceFollowControllerLike> | undefined
  if (typeof controller?.follow !== 'function') {
    log.warn('workspaceController has no follow face — workspace/follow will refuse as internal-error')
    return undefined
  }
  const readable = controller as WorkspaceFollowControllerLike
  const note = signatureNoteOf(readable, 'follow', ['signal'])
  if (note !== undefined) log.warn('workspace follow: calling positionally', { note })
  return (signal) => readable.follow(signal)
}

/** 本模块用到的 `ctx.workspaceController.follow` 部分 —— 签名与运行时逐字一致。 */
interface WorkspaceFollowControllerLike {
  follow(signal: AbortSignal): AsyncIterable<WorkspaceFollowFrame>
}

/**
 * 跟流（follow stream）的来源，取自宿主的 session controller。一次断言到泵使用的
 * 窄切面（`FollowSource`）；controller 只存在于 web-app bundle 中，
 * cordis 会持有本插件直到它出现。
 */
export function streamSourceOver(ctx: HostContext): FollowSource {
  // 断言直接点名 `ports/follow.ts` 的形状而非重写一遍：这里的第二份拷贝曾静默过期
  // （漏了 `turnWindow`）。
  const controller = ctx.sessionController as unknown as Pick<FollowSource, 'follow'>
  return {
    // 入参是上游的 `SessionFollowRequest`，原样递过去 —— 这一层不该认识窗口。
    follow: (request, signal) => controller.follow(request, signal),
    // control 流的基线：全部会话，与上游 `SessionControlController.baseline()` 同形。
    controlBaseline: () => {
      const read = ctx.sessionProjections as unknown as ProjectionsLike
      const sessions = ctx.sessions as unknown as SessionsLike
      const blocks: Record<string, { asOfSeq: number; values: Readonly<Record<string, unknown>> }> = {}
      for (const session of sessions.list()) {
        const snapshot = read.snapshot(session)
        if (snapshot === undefined) continue
        blocks[session.id] = { asOfSeq: snapshot.asOfSeq, values: snapshot.values }
      }
      return blocks
    },
  }
}

/** 本模块用到的 `ctx.sessions` 部分。 */
interface SessionsLike {
  get(id: string): unknown
  /** 全部已注册会话 —— control 的 Host-wide 基线用。 */
  list(): readonly { id: string }[]
}

/** 本模块用到的 `ctx.sessionProjections` 部分。 */
interface ProjectionsLike {
  /** 列表路径用的零 I/O 读取：只取已物化的格子，水位是*最低*的缓存切点。
   * 上游 `dsh-session-projection` 的 `cachedSnapshot` 将值文档化为可能落后于
   * 存活会话的提示。 */
  cachedSnapshot(session: unknown): ProjectionSnapshotLike | undefined
  /** 对已注册单元在日志当前水位的一次一致切取 —— 占用量帧用的读取，
   * 其 `asOfSeq` 必须前进，否则客户端会把它当重放丢掉。 */
  snapshot(session: unknown, keys?: readonly string[]): ProjectionSnapshotLike | undefined
}

/** 投影值的一次切取，上面两个读取都返回此形状。 */
interface ProjectionSnapshotLike {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * 协议层眼中的写通道，与其他来源一样取自宿主。
 *
 * `approval-answer` 交给中继；`session-prompt` 走 controller 的 prompt 门，
 * `session/not-found` 折叠为 `unknown-session`，其他上游失败原样重抛，
 * 让 `invokeEndpoint` 回答 `internal-error`。
 */
export function writePortOver(ctx: HostContext, relay: ApprovalRelay): WritePort {
  return {
    answerEvent: (result) => relay.answerEvent(result),
    promptSession: async (prompt) => pumpPrompt(promptControllerOver(ctx), prompt),
    createSession: (workspaceId) => createSession(ctx, workspaceId),
  }
}

/**
 * 建一个空会话，只交出宿主给的 id。
 *
 * 带 `workspaceId` 时宿主把会话建在那个工作空间的目录里并把它挂进成员表（cwd 与
 * attach 都由宿主负责，我们只传 id）；不带时目录仍由宿主的当前目录决定。
 * 宿主缺席这个切面时抛错，由协议层折成 `internal-error`。
 */
async function createSession(ctx: HostContext, workspaceId: string | undefined): Promise<string> {
  const controller = ctx.sessionController as unknown as Partial<SessionCreateControllerLike> | undefined
  if (controller?.create === undefined) {
    throw new Error('sessionController has no create face')
  }
  const created = await controller.create(workspaceId === undefined ? {} : { workspaceId })
  return created.sessionId
}

/** `session.create` 调用的 `ctx.sessionController` 部分。两个位置二选一，由宿主判。 */
interface SessionCreateControllerLike {
  create(request: { cwd?: string; workspaceId?: string }): Promise<{ sessionId: string }>
}

/**
 * 协议层眼中的模型通道，建立在会话控制器上。
 * 缺席是组装层事实，因此在组装时宣布，之后这些操作
 * 以 `internal-error` 信封应答 —— 手机绝不能把「本应拒答」看成死连接。
 *
 * **目录是转发**：`modelCatalog()` 交出的就是线上形状（四个键，含 `routableProviders`），
 * 这里不重建它 —— 重建一次就会漏一格，而漏掉不会编译失败。
 *
 * **选择要翻码**：上游的 not-found 是 `unknown-session`，`session/model-unavailable`
 * 原码透传（「换一个模型或修凭证」与「载荷畸形」是两种补救）。
 */
export function modelChannelOver(ctx: HostContext): ModelPort | undefined {
  const controller = ctx.sessionController as unknown as Partial<ModelControllerLike> | undefined
  if (
    controller === undefined ||
    typeof controller.selectModel !== 'function' ||
    typeof controller.modelCatalog !== 'function'
  ) {
    log.warn('sessionController has no model face — model-catalog/model-select will refuse as internal-error')
    return undefined
  }
  const readable = controller as ModelControllerLike
  // 组装期签名检查：两个成员都按位置调用，形参表变了要在启动时出声，
  // 而不是第一次点模型时（G2 的同族防线）。
  for (const [member, expected] of [
    ['selectModel', ['request']],
    ['modelCatalog', []],
  ] as const) {
    const note = signatureNoteOf(readable, member, expected)
    if (note !== undefined) log.warn('model channel: calling positionally', { note })
  }

  return {
    catalog: () => readable.modelCatalog(),
    async select(request) {
      try {
        const answer = await readable.selectModel({ ...request })
        return { ok: true, selected: { ...answer.selected } }
      } catch (error) {
        if (isNotFound(error)) {
          return { ok: false, code: 'unknown-session', message: String((error as { message?: unknown }).message ?? error) }
        }
        if (isRemoteError(error)) {
          return { ok: false, code: error.code as 'session/model-unavailable', message: String((error as { message?: unknown }).message ?? error) }
        }
        throw error
      }
    },
  }
}

/** 本模块用到的 `ctx.sessionController` 模型两面 —— 签名与运行时逐字一致。 */
interface ModelControllerLike {
  selectModel(request: {
    sessionId: string
    provider: string
    model: string
    reasoningEffort?: string
  }): Promise<{ selected: ModelSelection }>
  modelCatalog(): Promise<ModelCatalog>
}

/**
 * 协议层眼中的命令通道。
 *
 * **`commands` 不在 `inject` 里**，所以这里必须经 `ctx.reflect.get` 取，不能写成
 * `ctx.commands`：cordis 对没注入的服务属性一读就抛（`cannot get property "commands"
 * without inject`），而 `apply` 是在启动时跑的 —— 一次读就把整个插件打死，连读会话、
 * 发消息、推流一起停。
 *
 * 它也不该进 `inject`：命令是扩展，不是网关的核心。注入它等于让整个网关等一个可选插件，
 * 插件缺席时 fiber 永远 pending —— 那比「两条命令 op 拒答」糟得多，而且没有任何输出。
 *
 * 所以取数发生在**调用时**：拿到就缓存，拿不到就抛，由协议层折成 `internal-error`
 * （手机看到的是拒答，不是死连接）。命令插件晚于网关就绪时，下一次调用自己接上。
 *
 * 命令集是 per-agent 的，所以要同时在手的是会话注册表（取存活 agent）与命令服务本身；
 * 前者在 `inject` 里，照常直接读。
 */
export function commandChannelOver(ctx: HostContext): CommandPort {
  let resolved: CommandPort | undefined
  return {
    list: sessionId => port().list(sessionId),
    execute: (sessionId, line) => port().execute(sessionId, line),
  }

  function port(): CommandPort {
    if (resolved !== undefined) return resolved
    const commands = ctx.reflect.get('commands') as Partial<CommandsLike> | undefined
    const agents = ctx.agents as Partial<LiveAgentsLike> | undefined
    if (
      typeof commands?.list !== 'function' ||
      typeof commands.execute !== 'function' ||
      typeof agents?.get !== 'function'
    ) {
      throw new Error('commands service has no command face — command ops cannot be served')
    }
    resolved = commandPortOver(commands as CommandsLike, agents as LiveAgentsLike)
    log.info('command channel wired')
    return resolved
  }
}

/**
 * 协议层眼中的权限通道 —— **只剩目录的读**。
 *
 * `permissionPresets` 不在 `inject` 里（它是扩展，缺席不该让整个网关 pending），所以经
 * `ctx.reflect.get` 取、调用时解析并缓存 —— 插件晚于网关就绪时，下一次调用自己接上。
 *
 * **能力缺席不是错误**：预设服务不在时端口照常应答，只是三键一起缺席 —— 手机据此不画
 * 那一格。切档不在这条通道上（走命令域），当前值也不在（走 `permissions` 投影）。
 */
export function permissionChannelOver(ctx: HostContext): PermissionPort {
  let resolved: PermissionPort | undefined
  return {
    catalog: () => port().catalog(),
  }

  function port(): PermissionPort {
    if (resolved !== undefined) return resolved
    const presets = ctx.reflect.get('permissionPresets') as Partial<PermissionPresetsLike> | undefined
    if (typeof presets?.catalog !== 'function') {
      log.info('permission channel: no permission-presets service — the client hides the cell')
      resolved = ABSENT_PERMISSION
      return resolved
    }
    const readable = presets as PermissionPresetsLike
    // 组装期签名检查：目录走的是预设服务的 `catalog()`，形参表变了要在启动时出声，
    // 而不是第一次点格子时。
    const note = signatureNoteOf(readable, 'catalog', [])
    if (note !== undefined) log.warn('permission adapter: calling positionally', { note })

    resolved = permissionPortOver({ catalog: () => readable.catalog() })
    log.info('permission channel wired')
    return resolved
  }
}

/** 预设服务缺席时的端口：目录答「三键缺席」，客户端据此不画那一格。 */
const ABSENT_PERMISSION: PermissionPort = {
  async catalog() {
    return undefined
  },
}

/** 本模块用到的 `ctx.permissionPresets` 部分 —— 目录原样。 */
interface PermissionPresetsLike {
  catalog(): PermissionCatalog
}

/**
 * 网关在装配处的切面：**两个门，两个消费者**。开流门归 `ForwardedEvents`（进程一份的
 * `$events` 身份），应答门归审批中继；本函数把它们一次解析出来并共享同一个 Peer。
 *
 * `ctx.typertGateway` 拿到的是被 traceable/严格视图包过的成员，
 * 异步生成器方法包装后不再可迭代（真机日志 `openWireStream is not a function or
 * its return value is not async iterable`）—— 用全局注册表 symbol
 * `Symbol.for('cordis.original')`（cordis 的 `originalOf` 逃生口）即可解出原始实例。
 *
 * 原始实例的**形参位置**也会变 —— 0.1.7 把 `uplink` / `peer` 插在 `signal`
 * 前，按位置传的取消信号落进 uplink 槽，`AbortSignal.any([undefined, ...])` 当场抛错
 * （真机日志 `signals[0] is not of type AbortSignal.`）。对策：收流优先走**声明面**
 * `wireStream.open`（types.d.ts:87）；缺席才碰私有 `openWireStream`，实参**按形参名**填
 * （`openStreamThrough`），形参表读不出（bind/native 包过）时按 arity 兜底并告警。
 *
 * 本函数还负责它们共同的**身份**：向 `connection` 服务要一个进程内 Peer（{@link peerFor}）——
 * 自 0.2 起开流必须以一个真实 Peer 的名义，而它在该版是必需实参（R11）。
 */
export function gatewayOver(ctx: HostContext): RemoteEventStreamLike & RemoteEventAnswerLike {
  const view = ctx.typertGateway as unknown as Record<PropertyKey, unknown> | undefined
  if (view === undefined || typeof view !== 'object') {
    throw new Error('ctx.typertGateway is unavailable — the web profile did not provide the gateway service')
  }
  const raw = (typeof view[Symbol.for('cordis.original')] === 'object' && view[Symbol.for('cordis.original')] !== null
    ? view[Symbol.for('cordis.original')]
    : view) as Record<PropertyKey, unknown>

  const members = `openWireStream=${typeof raw.openWireStream}, wireStream=${typeof raw.wireStream}, dispatchRpc=${typeof raw.dispatchRpc}`
  const member = raw.dispatchRpc
  if (typeof member !== 'function') {
    // 应答门是中继存在的全部理由：缺失必须在对齐时暴露，
    // 而不是在第一次点击应答时。
    log.error('approval relay gateway members', { members })
    throw new Error('ctx.typertGateway exposes no dispatchRpc — the approval relay cannot answer without it')
  }
  // `typeof x === 'function'` 只收窄到 `Function`（上游声明里它是类方法，形参表不可读）；
  // 交给 `callThrough` 前按它的契约收面，返回结局由 `RemoteEventGatewayLike` 定。
  const dispatchRpc = member as (...args: unknown[]) => Promise<unknown>

  const declared = (typeof raw.wireStream === 'object' && raw.wireStream !== null ? raw.wireStream : undefined) as
    | { open?: unknown }
    | undefined
  const opening = typeof declared?.open === 'function' ? declared.open : raw.openWireStream
  if (typeof opening !== 'function') {
    log.error('gateway face members', { members })
    throw new Error('ctx.typertGateway exposes neither wireStream.open nor openWireStream — the $events source cannot run')
  }
  const opener = opening as (...args: unknown[]) => Promise<AsyncIterable<unknown>>
  // 两个候选开流者的归属不同：声明面 `wireStream.open` 是**字段**（挂在 `wireStream` 上，
  // 且上游写成箭头函数、不依赖 this），私有兜底 `openWireStream` 是**方法**（必须带 raw）。
  const declaredOpener = opener === declared?.open
  const openerOwner = declaredOpener ? declared : raw
  log.info(
    `gateway face: ${declaredOpener ? 'wireStream.open (declared)' : 'openWireStream (private)'} + dispatchRpc`,
  )
  // 必需实参有两个：取消信号与 peer。这里只对 `signal` 报警，是因为 `peer` 另有兜底
  // （`positionalArguments` 的 4 / 5 档都带它）；而拼写不匹配的信号在重连循环里是看不见的，
  // 所以必须在装配时说出来。
  const names = parameterNamesOf(opener)
  if (names === undefined || !names.includes('signal')) {
    log.warn(
      `gateway face: the stream opener declares ${names === undefined ? 'no readable parameters' : `no \`signal\` (${names.join(', ')})`}; feeding it positionally, cancellation last. reads: ${Function.prototype.toString.call(opener).slice(0, 160)}`,
    )
  }

  // 开流的身份：一次取定，两个端口共用（应答路径按对象相等校验身份，见 peerFor）。
  const peer = peerFor(ctx)

  return {
    // `$events` 说的是上游源的词汇，所以仅在这一个边界把流类型按此标注 ——
    // opener 本身在上游是无类型的。
    openWireStream: (endpoint, payload, signal) =>
      openStreamThrough(opener, { endpoint, payload, peer, signal }, openerOwner) as Promise<AsyncIterable<UpstreamWireFrame>>,
    // 与 opener 同理：应答门同样是私有成员，形参也可能移动；而它是**实例方法**，
    // 接收者必须是 raw（见 callThrough 的注释：丢 this 就是丢应答）。
    dispatchRpc: (endpoint, payload, signal) => callThrough(dispatchRpc, { endpoint, payload, signal, peer }, raw),
  }
}

/**
 * 开流与应答所代表的身份（上游 `PeerScope`）。
 *
 * 上游自 0.2 起把 `peer` 列为**必需**，且在开流时解引用它（`assertPeerLive` 读
 * `peer.signal.aborted`）；而进程内调用者没有连接准入那条路 —— 上游为此在 `connection`
 * 服务上开了 `createPeer`（其声明注释：Create one in-process Peer owned by the Context
 * that read this service）。取 `owner` + `answer`：前者是应答路径的准入要求，后者是开
 * forwarded-event 流的要求。
 *
 * **一次取定、两个端口共用**：应答路径按**对象相等**校验身份（上游 `client.peer !== peer`
 * 即拒），两处各造一个会在「点批准」那一刻才失败 —— 比开流失败更晚、更难查。
 */
function peerFor(ctx: HostContext): PeerScopeLike {
  const connection = (ctx as unknown as { connection?: { createPeer?: unknown } }).connection
  const createPeer = connection?.createPeer
  if (typeof createPeer !== 'function') {
    // 这一段是我们与宿主的接线，缺了它中继整块不可用 —— 在装配时说清，而不是把
    // `undefined` 传进每一代建流（R11 修的正是后者）。
    log.error('approval relay peer source',
      { connection: typeof connection, createPeer: typeof createPeer })
    throw new Error('ctx.connection.createPeer is unavailable — the approval relay cannot open $events without a Peer')
  }
  const peer = (createPeer as (options: unknown) => unknown).call(connection, {
    principal: { kind: 'owner' },
    interactions: 'answer',
  })
  const problem = peerShapeProblem(peer)
  if (problem !== undefined) {
    log.error('approval relay peer: createPeer returned an unusable Peer', { problem })
    throw new Error(`ctx.connection.createPeer returned a Peer that is ${problem} — the approval relay cannot speak for it`)
  }
  log.info('approval relay peer: owner/answer via connection.createPeer')
  return peer as PeerScopeLike
}

/**
 * `undefined` = 形状可用，否则是缺的那一项（拼进错误信息）。做成纯函数是为了让「装配期
 * 探测探什么」可被单测直接钉住：中继要的是 `principal`、`signal`（宿主会解引用）与
 * `interactions=answer`（否则开不了 `$events`）。**判据是「成员与能力」，不是「形参名
 * 读得出」** —— 后者在宿主把服务成员包成 native 时一律失效，报出来就是误报。
 */
export function peerShapeProblem(peer: unknown): string | undefined {
  if (typeof peer !== 'object' || peer === null) return 'not an object'
  const record = peer as Record<string, unknown>
  if (typeof record.principal !== 'object' || record.principal === null) return 'missing principal'
  if (!(record.signal instanceof AbortSignal)) return 'missing an AbortSignal signal'
  if (record.interactions !== 'answer') return 'missing interactions=answer'
  return undefined
}

/** prompt 泵调用的 `ctx.sessionController` 部分。 */
function promptControllerOver(ctx: HostContext): PromptControllerLike {
  return ctx.sessionController as unknown as PromptControllerLike
}
