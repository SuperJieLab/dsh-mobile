/**
 * DSH 适配器：唯一知道 session store 存在的模块。
 *
 * 它基于宿主服务实现契约的 `SessionPort`，使 `rpc.ts` 既不接触 DSH 也不接触 I/O；
 * 形状在本文件自行声明，因为真实类型在 dsh 安装目录之外无法解析
 * （`@deepseek-ai/dsh-session-persistence`: MODULE_NOT_FOUND）。
 *
 * ## 列表零 I/O（v2）
 *
 * v1 整读每份日志（O(sessions) 次全量读）；v2 不读任何日志。记录 = 头部 +
 * 是否存活；存活的值取自内存，冷的取自持久 checkpoint；缺失的投影保持缺失
 * —— 无 `title` 时 `updatedAt` 回退为 `createdAt`，绝不为了填一格去读日志。
 *
 * 代价：`updatedAt` 表示「上次说话的时间」，而非「最新事件时间」，且不承诺
 * 事件数（dev/contract/protocol.md §4.1）—— 只能从日志算出的字段不可能不读日志
 * 就给出。这就是 v2。
 *
 * `cwd === undefined` 的会话跳过，参照列表同样隐藏它；其余规则（subagent、
 * 归档、空白）属于客户端，而这一条本身已是头部事实。
 */
import type { ModelSelection } from '../contract/model-selection.ts'
import type { SessionPort, SessionRow, SessionSlice, WireEvent } from '../contract/rpc.ts'

/** 本适配器读取的头部字段。 */
interface HeaderLike {
  readonly id: string
  readonly createdAt: number
  /** 缺席表示该会话不作为普通工作区会话展示。 */
  readonly cwd?: string
  /**
   * 播种的日志继承自另一会话的前缀，而 checkpoint 的身份绑定在恰好那个前缀上
   * —— 头部本身并不命名它。所以播种会话只从头部供数，绝不走缓存。
   */
  readonly isSeeded?: boolean
  /** 子会话为 `'subagent'`；普通会话缺席。 */
  readonly origin?: string
}

/** `SessionHandle.read()` 的返回。 */
interface ReadResultLike {
  readonly events: readonly WireEvent[]
}

/** 本适配器用到的 `SessionHandle` 部分。 */
interface HandleLike {
  read(offset?: number, length?: number): Promise<ReadResultLike>
  close(): Promise<void>
}

/** 本适配器用到的 `SessionPersistence` 部分。 */
export interface PersistenceLike {
  open(id: string, access: 'read'): Promise<HandleLike>
}

/** 语料库给出的一条记录。 */
export interface ListRecord {
  readonly header: HeaderLike
  /** 该会话当前是否在内存中存活。 */
  readonly live: boolean
}

/**
 * 单个会话的投影值，按投影名索引。形状属于宿主（`title`、`sessionListMetadata`
 * 等），在此保持不透明：本文件只读自己需要的两格、忽略其余，因此上游明天新增
 * 投影不会弄坏列表。
 */
export type ProjectionValues = Readonly<Record<string, unknown>>

/**
 * 列表某一行原料的来源：四个窄方法而非服务本身，因为存活/冷的分支是适配器的
 * 决定（且有测试），而每个值怎么取得是宿主的事。
 */
export interface ListSource {
  /** 全部会话，头部加存活标记。 */
  records(): Promise<readonly ListRecord[]>
  /** 存活会话的投影，直接取自内存。 */
  liveValues(sessionId: string): ProjectionValues | undefined
  /** 冷会话的投影，取自持久 checkpoint。 */
  storedValues(header: HeaderLike): ProjectionValues | undefined
  /** 此会话当前是否有 agent 在运行。 */
  isRunning(sessionId: string): boolean
  /**
   * 每次 `list()` 中有一行或多行缺投影格子时调用一次 —— 计数交还给组装本来源的
   * 一方而不是在此吞掉，因为静默降级正是上游调用漂移看不见的原因。
   */
  onProjectionFailure?(failures: number, first: unknown): void
}

/** 本适配器从 `sessionListMetadata` 读出的格子。 */
interface SessionListMetadataLike {
  readonly blank?: boolean
  readonly lastPromptAt?: number | null
}

/**
 * `modelSelection` 投影的线上视图，宿主给出的形状（`{lastUsed, next}`）；
 * 只有 `next` 是基线 —— 即下一个请求将用的模型。
 */
export interface ModelSelectionView {
  next?: ModelSelection | null
}

/**
 * 会话模型基线的来源，`ListSource` 式的窄切面：由组装方从存活投影注册表填充。
 * 缺席（无会话对象、无投影）就是缺席 —— 基线只携带服务器能证明的东西。
 */
export interface ModelSelectionSource {
  of(sessionId: string): ModelSelectionView | undefined
}

/**
 * 基于宿主服务构建会话端口：`persistence` 读日志（供 `snapshot` 和 `page`），
 * `listing` 供给列表路径的原料，返回的端口即 `handle()` 读取的入口。
 * `modelSelection` 可选：缺席意味着每个分片都不带基线发出，对没有投影的组装
 * 而言这就是最诚实的答案。
 */
export function createSessionPort(persistence: PersistenceLike, listing: ListSource, modelSelection?: ModelSelectionSource): SessionPort {
  return {
    async list(): Promise<readonly SessionRow[]> {
      const rows: SessionRow[] = []
      let failures = 0
      let firstFailure: unknown
      for (const record of await listing.records()) {
        // 与参照列表同样方式隐藏，且在任何投影查找*之前*跳过 —— 不可见会话零成本。
        if (record.header.cwd === undefined) continue

        let values: ProjectionValues | undefined
        try {
          values = valuesFor(record, listing)
        } catch (error) {
          // 投影只是*提示*：一行的读取失败只损失该行的格子，绝不损失整个列表 ——
          // 这是上游 listing 划的线（`session-controller/src/list.ts` 的
          // `projectionsFor`，返回 `undefined` 并告警）。没有它，一份读不出的
          // checkpoint 会弄黑整屏。
          failures += 1
          firstFailure ??= error
        }

        const metadata = metadataOf(values)
        rows.push({
          id: record.header.id,
          ...titleOf(values),
          createdAt: record.header.createdAt,
          updatedAt: lastPromptAt(record.header, metadata),
          running: listing.isRunning(record.header.id),
          blank: metadata?.blank === true,
          ...record.header.origin === undefined ? {} : { origin: record.header.origin },
        })
      }
      if (failures > 0) listing.onProjectionFailure?.(failures, firstFailure)
      return rows
    },

    async read(id: string, since: number, limit: number): Promise<SessionSlice | undefined> {
      let handle: HandleLike
      try {
        handle = await persistence.open(id, 'read')
      } catch (error) {
        // 会话缺失是正常答案（`unknown-session`），不是故障。其余 open 失败一律
        // 向上传播，在契约层变成拒答。
        if ((error as { name?: unknown } | null)?.name === 'SessionPersistenceNotFoundError') return undefined
        throw error
      }

      try {
        // 上限之外多读一个事件：它的存在证明还有更多，契约因此永远不必猜日志
        // 到哪结束。
        const { events } = await handle.read(since, limit + 1)

        if (events.length === 0 && since > 0) {
          // 是追平了，还是游标越过末尾？只有日志能回答，也只能按日志能证明的答：
          // 空日志不可能包含位置 1。`since` 仅越过水位时与「追平」不可区分，
          // 保持为正常的空答案（dev/contract/protocol.md §五；M1 §3.3.2 决定 5）。
          const head = await handle.read(0, 1)
          if (head.events.length === 0) {
            return { events: [], asOfSeq: 0, hasMore: false, staleCursor: true }
          }
        }

        const hasMore = events.length > limit
        const kept = hasMore ? events.slice(0, limit) : events
        const last = kept.at(-1)
        return {
          events: kept,
          asOfSeq: last === undefined ? since : last.seq + 1,
          hasMore,
          staleCursor: false,
          // 模型基线：投影的 `next` 原样，投影缺席则字段缺席 ——
          // 绝不给 null，绝不猜默认值。
          ...baselineOf(id, modelSelection),
        }
      } finally {
        await handle.close().catch(() => {})
      }
    },

    async readAll(id: string): Promise<readonly WireEvent[] | undefined> {
      let handle: HandleLike
      try {
        handle = await persistence.open(id, 'read')
      } catch (error) {
        if ((error as { name?: unknown } | null)?.name === 'SessionPersistenceNotFoundError') return undefined
        throw error
      }

      try {
        return (await handle.read()).events
      } finally {
        await handle.close().catch(() => {})
      }
    },
  }
}

/** 分片可选的 `model` 字段：投影的 `next`，否则什么都没有。 */
function baselineOf(id: string, modelSelection: ModelSelectionSource | undefined): { model?: ModelSelection } {
  const next = modelSelection?.of(id)?.next
  return next === undefined || next === null ? {} : { model: next }
}

/**
 * 单条记录投影的来源：存活会话取内存（其值随工作变动），已结束会话取持久
 * checkpoint（其日志不再变化，checkpoint 即终值而非过期值）。可能抛错；调用方
 * 降级行而非列表（见 `list`）。
 */
function valuesFor(record: ListRecord, listing: ListSource): ProjectionValues | undefined {
  if (record.live) return listing.liveValues(record.header.id)
  if (record.header.isSeeded === true) return undefined
  return listing.storedValues(record.header)
}

/** `sessionListMetadata` 格子，仅当投影带出了可用的值。 */
function metadataOf(values: ProjectionValues | undefined): SessionListMetadataLike | undefined {
  const cell = values?.sessionListMetadata
  if (typeof cell !== 'object' || cell === null) return undefined
  return cell as SessionListMetadataLike
}

/**
 * 标题格：凡不是字符串 —— 包括无标题会话携带的 `null` —— 一律视为「无标题」，
 * 字段因此缺席而非空串（dev/contract/protocol.md §4.1）。
 */
function titleOf(values: ProjectionValues | undefined): { title?: string } {
  const cell = values?.title
  return typeof cell === 'string' ? { title: cell } : {}
}

/**
 * 行的活动时间：最后一次用户 prompt，不早于创建时间 —— 刻意不是「最新事件时间」，
 * 那需要读日志，恰是 v2 列表要避免的。
 */
function lastPromptAt(header: HeaderLike, metadata: SessionListMetadataLike | undefined): number {
  const promptAt = metadata?.lastPromptAt
  return typeof promptAt === 'number' ? Math.max(header.createdAt, promptAt) : header.createdAt
}
