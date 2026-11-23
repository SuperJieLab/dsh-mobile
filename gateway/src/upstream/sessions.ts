/**
 * DSH 适配器：唯一知道 session store 存在的模块。
 *
 * 它基于宿主服务实现契约的 `SessionPort`，使 `rpc.ts` 既不接触 DSH 也不接触 I/O；
 * 形状在本文件自行声明，因为真实类型在 dsh 安装目录之外无法解析
 * （`@deepseek-ai/dsh-session-persistence`: MODULE_NOT_FOUND）。
 *
 * ## 只剩读路径
 *
 * 列表已改为转发宿主的 `session/list`（见 `upstream/faces.ts` 的 `sessionListFace`），
 * 所以本文件只剩「读一条会话的事件」两件事：自水位前向读（`snapshot`）与整条日志
 * （反向窗口的 `page` 需要日志末端）。
 */
import type { ModelSelection } from '../wire/model.ts'
import type { SessionPort } from '../ports/session.ts'
import type { SessionSlice, WireEvent } from '../wire/rpc.ts'

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

/**
 * **宿主**的 `modelSelection` 投影视图（不是我们的形状）：`{lastUsed, next}` 里
 * 本适配器只声明读到的那一格 —— 宿主给视图加一格时不该弄坏这里。
 *
 * 名字带 `Host`：它与 `ModelSelection`（我们的、要上线的）是两个东西，
 * 转换只有一处（{@link nextOf}）。
 */
export interface HostModelSelectionView {
  next?: ModelSelection | null
}

/**
 * 宿主视图 → 我们的选择：「下一轮将用哪个模型」。
 *
 * 这是两种形状之间**唯一**的转换点，所以它有名字。`lastUsed`（上一轮用了什么）
 * 刻意不取：协议里 `model` 的语义是「下一轮将用什么」，让每个消费者自己去挑字段，
 * 等于把一个语义判断交给两端各实现一遍 —— 而漏挑的那一处不会编译报错。
 */
export function nextOf(view: HostModelSelectionView): ModelSelection | undefined {
  const next = view.next
  return next === undefined || next === null ? undefined : next
}

/**
 * 会话模型基线的来源，窄切面：由组装方从存活投影注册表填充。
 * 返回的是**选择本身**，不是宿主的视图 —— 提取在这里就完成，调用方拿不到整份视图，
 * 也就无法把整份视图发出去。
 *
 * 缺席（无会话对象、无投影、`next` 为空）就是缺席 —— 基线只携带服务器能证明的东西。
 */
export interface ModelSelectionSource {
  of(sessionId: string): ModelSelection | undefined
}

/**
 * 基于宿主服务构建会话端口的**读路径**：`persistence` 读日志（供 `snapshot` 和
 * `page`）。`modelSelection` 可选：缺席意味着每个分片都不带基线发出，对没有投影
 * 的组装而言这就是最诚实的答案。
 *
 * `list` 不在这里 —— 它是转发，由组装层直接接宿主的 `session/list`（`index.ts`）。
 */
export function createSessionPort(
  persistence: PersistenceLike,
  modelSelection?: ModelSelectionSource,
): Omit<SessionPort, 'list'> {
  return {
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
          // 保持为正常的空答案 —— 这两件事在日志上同形，协议不假装能分开。
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
          // 模型基线：来源给的选择原样，来源没有就给不出 —— 两种空值早在上游
          // 折完（`nextOf`），这一层不做判断，也绝不猜默认值。
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

/**
 * 分片可选的 `model` 字段：来源给出的选择，否则什么都没有。
 * `null` 不在这里判 —— 它已被 {@link nextOf} 折成 `undefined`，本函数的入参
 * 类型也说不会有第二种空值。在这一层再判一次，只会造出一条**不可达**的分支
 * 和一条喂假值的断言（那正是本期缺陷的成因：断言对着真实来源不会产生的形状写）。
 */
function baselineOf(id: string, modelSelection: ModelSelectionSource | undefined): { model?: ModelSelection } {
  const selection = modelSelection?.of(id)
  return selection === undefined ? {} : { model: selection }
}
