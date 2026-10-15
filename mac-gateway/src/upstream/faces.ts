/**
 * 网关眼中的 DSH 宿主切面：包括宿主真实类型迫使我们声明的全部窄接口
 * （`*Like`，它们在 dsh 安装目录之外无法解析），以及基于宿主服务构建网关侧
 * 端口的全部 `*Over(ctx)` 工厂。组装层（`index.ts`）只调用这些工厂。
 *
 * 这里的类型断言是有意的：每个服务只断言到消费方适配器声明的窄形状，
 * 不再多断。
 */
import type { Context } from '@deepseek-ai/cordis'
import { usageSnapshotOf } from '../contract/usage.ts'
import type { WritePort } from '../contract/write-channel.ts'
import type { ModelPort } from '../contract/model-selection.ts'
import { createSessionPort, type ListSource, type ModelSelectionSource, type ModelSelectionView, type PersistenceLike } from './sessions.ts'
import type { FollowSource } from '../remote/ws.ts'
import { modelPortOver, type ModelControllerLike } from './model.ts'
import { callThrough, openStreamThrough, parameterNamesOf, type PeerScopeLike } from './call-through.ts'
import { ApprovalRelay, pumpPrompt, type PromptControllerLike, type RemoteEventGatewayLike, type UpstreamWireFrame } from './write.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.faces)

/**
 * 列表路径的来源，由宿主服务组装 —— 每一项都对应参照列表做的一件事
 * （M1 §2.2）：记录来自语料库（头部 +
 * 存活性），值在运行会话取存活投影、冷会话取存储 checkpoint，存活性来自
 * agent 注册表。
 *
 * 这里没有任何日志读取。
 */
export function listSourceOver(ctx: Context): ListSource {
  return {
    async records() {
      const records = await (ctx.sessionQuery as unknown as CorpusLike).listSessions()
      return records.map(record => ({ header: record.header, live: record.live }))
    },

    liveValues(sessionId) {
      const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
      if (session === undefined) return undefined
      return (ctx.sessionProjections as unknown as ProjectionsLike).cachedSnapshot(session)?.values
    },

    storedValues(header) {
      const cache = ctx.sessionProjectionCache as unknown as ProjectionCacheLike
      const snapshot = cache.cachedSnapshot(header) ?? cache.cachedPredecessorTitle(header)
      return snapshot?.values
    },

    isRunning(sessionId) {
      return (ctx.agents as unknown as AgentsLike).get(sessionId)?.status === 'running'
    },

    // 没有投影的行仍是正确的行，但*静默*降级曾让缓存参数漂移一直不可见，
    // 直到手机端显示空白屏幕，所以计数要进日志。
    onProjectionFailure: (failures, first) => {
      log.warn(
        `${failures} session row(s) served without projections — first failure: ${String(first)}`,
      )
    },
  }
}

/**
 * 跟流（follow stream）的来源，取自宿主的 session controller。一次断言到泵使用的
 * 窄切面（`FollowSource`）；controller 只存在于 web-app bundle 中，
 * cordis 会持有本插件直到它出现。
 */
/** 占用量读取所基于的投影键 —— 具名常量使读取不会物化无人消费的视图。 */
const OCCUPANCY_KEYS = ['contextPressure', 'contextBreakdown'] as const

export function streamSourceOver(ctx: Context): FollowSource {
  // 断言直接点名 `ws.ts` 的形状而非重写一遍：这里的第二份拷贝曾静默过期
  // （漏了 `turnWindow`）。
  const controller = ctx.sessionController as unknown as Pick<FollowSource, 'follow'>
  return {
    follow: (request, signal) => controller.follow(request, signal),
    occupancyOf: (sessionId) => {
      const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
      if (session === undefined) return undefined
      const read = ctx.sessionProjections as unknown as ProjectionsLike
      const snapshot = read.snapshot(session, OCCUPANCY_KEYS)
      return snapshot === undefined ? undefined : usageSnapshotOf(snapshot.values, snapshot.asOfSeq)
    },
    // 模型基线随开流走：与 snapshot 路径相同的投影读取，只是时刻更早 ——
    // 开流是存活会话走的路径。
    modelOf: (sessionId) => modelSelectionViewOf(ctx, sessionId),
  }
}

/** 本模块用到的 `ctx.sessionQuery` 部分。 */
interface CorpusLike {
  listSessions(): Promise<readonly { header: never; live: boolean }[]>
}

/** 本模块用到的 `ctx.sessions` 部分。 */
interface SessionsLike {
  get(id: string): unknown
}

/** 本模块用到的 `ctx.sessionProjections` 部分。 */
interface ProjectionsLike {
  /** 列表路径用的零 I/O 读取：只取已物化的格子，水位是*最低*的缓存切点。
   * 上游 `dsh-session-projection` 的 `cachedSnapshot` 将值文档化为可能落后于
   * 存活会话的提示。 */
  cachedSnapshot(session: unknown): ProjectionSnapshotLike | undefined
  /** 对已注册单元在日志当前水位的一次一致切取 —— 占用量帧用的读取，
   * 其 `asOfSeq` 必须前进（M6 §3.1 决定 3）。 */
  snapshot(session: unknown, keys?: readonly string[]): ProjectionSnapshotLike | undefined
}

/** 投影值的一次切取，上面两个读取都返回此形状。 */
interface ProjectionSnapshotLike {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * 本模块用到的 `ctx.sessionProjectionCache` 部分。⚠️ **位置漂移风险**：本构建
 * 依赖的运行时（0.1.7-alpha.2）中，切面是 `cachedSnapshot(meta, keys?)` /
 * `cachedPredecessorTitle(meta)`
 * （dsh-session-projection-cache/lib/index.js:193,214）—— 头部单独承载生命周期
 * 身份，且是此处给出的唯一实参，与运行时自己的列表调用一致
 * （dsh-api-session-controller/lib/index.js:1917）。更早的签名带一个
 * `inheritedEventCount` 前缀实参；对漂移后的切面按位置传参，实参会落进 `keys`。
 */
interface ProjectionCacheLike {
  cachedSnapshot(header: never): { asOfSeq: number; values: Readonly<Record<string, unknown>> } | undefined
  cachedPredecessorTitle(header: never): { asOfSeq: number; values: Readonly<Record<string, unknown>> } | undefined
}

/** 本模块用到的 `ctx.agents` 部分。 */
interface AgentsLike {
  get(id: string): { status?: string } | undefined
}

/**
 * 单个会话的 `modelSelection` 投影线上视图 —— snapshot 基线与跟流
 * 开场的 `model` 字段共用的那次读取。缺席（会话不存活）是诚实的 —— 字段保持
 * 缺席而非猜默认值。
 */
function modelSelectionViewOf(ctx: Context, sessionId: string): ModelSelectionView | undefined {
  const session = (ctx.sessions as unknown as SessionsLike).get(sessionId)
  if (session === undefined) return undefined
  const read = ctx.sessionProjections as unknown as ProjectionsLike
  const snapshot = read.snapshot(session, ['modelSelection'])
  const view = snapshot?.values.modelSelection
  if (typeof view !== 'object' || view === null) return undefined
  return view as ModelSelectionView
}

export function modelSelectionSourceOver(ctx: Context): ModelSelectionSource {
  return {
    of: (sessionId) => modelSelectionViewOf(ctx, sessionId),
  }
}

/**
 * 协议层眼中的写通道，与其他来源一样取自宿主。
 *
 * `approval-answer` 交给中继；`session-prompt` 走 controller 的 prompt 门，
 * `session/not-found` 折叠为 `unknown-session`，其他上游失败原样重抛，
 * 让 `handle` 回答 `internal-error`。
 */
export function writePortOver(ctx: Context, relay: ApprovalRelay): WritePort {
  return {
    answerApproval: (answer) => relay.answerApproval(answer),
    promptSession: async (prompt) => pumpPrompt(promptControllerOver(ctx), prompt),
  }
}

/**
 * 协议层眼中的模型通道，建立在中继与泵共用的同一 controller 上。
 * 缺席是组装层事实，因此在组装时宣布，之后这些操作
 * 以 `internal-error` 信封应答 —— 手机绝不能把「本应拒答」看成死连接。
 */
export function modelChannelOver(ctx: Context): ModelPort | undefined {
  const controller = ctx.sessionController as unknown as Partial<ModelControllerLike> | undefined
  if (
    controller === undefined ||
    typeof controller.selectModel !== 'function' ||
    typeof controller.modelCatalog !== 'function'
  ) {
    log.warn('sessionController has no model face — model-catalog/model-select will refuse as internal-error')
    return undefined
  }
  return modelPortOver(controller as ModelControllerLike)
}

/**
 * 审批中继所驱动的网关服务切面。
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
 * 本函数还负责中继的**身份**：向 `connection` 服务要一个进程内 Peer（{@link peerFor}）——
 * 自 0.2 起开流必须以一个真实 Peer 的名义，而它在该版是必需实参（R11）。
 */
export function gatewayOver(ctx: Context): RemoteEventGatewayLike {
  const view = ctx.typertGateway as unknown as Record<PropertyKey, unknown> | undefined
  if (view === undefined || typeof view !== 'object') {
    throw new Error('ctx.typertGateway is unavailable — the web profile did not provide the gateway service')
  }
  const raw = (typeof view[Symbol.for('cordis.original')] === 'object' && view[Symbol.for('cordis.original')] !== null
    ? view[Symbol.for('cordis.original')]
    : view) as Record<PropertyKey, unknown>

  const members = `openWireStream=${typeof raw.openWireStream}, wireStream=${typeof raw.wireStream}, dispatchRpc=${typeof raw.dispatchRpc}`
  const dispatchRpc = raw.dispatchRpc
  if (typeof dispatchRpc !== 'function') {
    // 应答门是中继存在的全部理由：缺失必须在对齐时暴露，
    // 而不是在第一次点击应答时。
    log.error(`approval relay gateway members: ${members}`)
    throw new Error('ctx.typertGateway exposes no dispatchRpc — the approval relay cannot answer without it')
  }

  const declared = (typeof raw.wireStream === 'object' && raw.wireStream !== null ? raw.wireStream : undefined) as
    | { open?: unknown }
    | undefined
  const opening = typeof declared?.open === 'function' ? declared.open : raw.openWireStream
  if (typeof opening !== 'function') {
    log.error(`approval relay gateway members: ${members}`)
    throw new Error('ctx.typertGateway exposes neither wireStream.open nor openWireStream — approval relay cannot run')
  }
  const opener = opening as (...args: unknown[]) => Promise<AsyncIterable<unknown>>
  // 两个候选开流者的归属不同：声明面 `wireStream.open` 是**字段**（挂在 `wireStream` 上，
  // 且上游写成箭头函数、不依赖 this），私有兜底 `openWireStream` 是**方法**（必须带 raw）。
  const declaredOpener = opener === declared?.open
  const openerOwner = declaredOpener ? declared : raw
  log.info(
    `approval relay gateway: ${declaredOpener ? 'wireStream.open (declared)' : 'openWireStream (private)'} + dispatchRpc`,
  )
  // 必需实参有两个：取消信号与 peer。这里只对 `signal` 报警，是因为 `peer` 另有兜底
  // （`positionalArguments` 的 4 / 5 档都带它）；而拼写不匹配的信号在重连循环里是看不见的，
  // 所以必须在装配时说出来。
  const names = parameterNamesOf(opener)
  if (names === undefined || !names.includes('signal')) {
    log.warn(
      `approval relay: the stream opener declares ${names === undefined ? 'no readable parameters' : `no \`signal\` (${names.join(', ')})`}; feeding it positionally, cancellation last. reads: ${Function.prototype.toString.call(opener).slice(0, 160)}`,
    )
  }

  // 开流的身份：一次取定，两个端口共用（应答路径按对象相等校验身份，见 peerFor）。
  const peer = peerFor(ctx)

  return {
    // `$events` 说的是中继自己的词汇，所以仅在这一个边界把流类型按此标注 ——
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
function peerFor(ctx: Context): PeerScopeLike {
  const connection = (ctx as unknown as { connection?: { createPeer?: unknown } }).connection
  const createPeer = connection?.createPeer
  if (typeof createPeer !== 'function') {
    // 这一段是我们与宿主的接线，缺了它中继整块不可用 —— 在装配时说清，而不是把
    // `undefined` 传进每一代建流（R11 修的正是后者）。
    log.error(`approval relay peer source: connection=${typeof connection}, createPeer=${typeof createPeer}`)
    throw new Error('ctx.connection.createPeer is unavailable — the approval relay cannot open $events without a Peer')
  }
  const peer = (createPeer as (options: unknown) => unknown).call(connection, {
    principal: { kind: 'owner' },
    interactions: 'answer',
  })
  const problem = peerShapeProblem(peer)
  if (problem !== undefined) {
    log.error(`approval relay peer: createPeer returned a Peer that is ${problem}`)
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

/** 中继的广播切面：WS 适配器的 socket 集合要等监听 effect 运行才存在，
 * 所以中继立刻拿到一个可广播的切面，适配器稍后自行接入。 */
export function broadcasterOver(): {
  broadcast(frame: unknown): void
  connect(sink: (frame: unknown) => void): void
} {
  let sink: ((frame: unknown) => void) | undefined
  return {
    broadcast: (frame) => sink?.(frame),
    connect: (fn) => { sink = fn },
  }
}

/** prompt 泵调用的 `ctx.sessionController` 部分。 */
function promptControllerOver(ctx: Context): PromptControllerLike {
  return ctx.sessionController as unknown as PromptControllerLike
}
