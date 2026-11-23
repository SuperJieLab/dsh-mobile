/**
 * `workspace/follow` 的线上形状 —— 与上游 `WorkspaceFollowFrame` 同形。
 *
 * **七种帧**：打开时一条 `baseline`（完整状态），之后六种增量。`replace` 与 `baseline`
 * 同形但语义不同：它替换这一代里此前发过的一切，不是新一代的开口帧。
 *
 * 与 `session/control` 的 `baseline` **同名不同形** —— 那是投影表（`{projections}`），
 * 这是组清单（`{items, archivedSessionIds, pinnedSessionIds}`）。客户端的解码因此按流做：
 * 一条流只认自己那几种货物，同名的那一格不会互相遮挡。
 *
 * 字段名与上游逐字相同（`workspaceId` 而不是 `id`、`sessionIds` 而不是 `sessions`）：
 * 改一个名客户端就解不出，而两端各自的判据都还绿 —— 所以共守样本里要有一条。
 */

/** 一个组 —— 宿主 `WorkspaceView` 的逐字形状。 */
export interface WorkspaceView {
  readonly workspaceId: string
  /** 宿主上的规范路径。客户端不展示、也不据此归并 —— 归属看 `sessionIds`。 */
  readonly path: string
  /** 给人看的组名（由目录名派生，宿主不改写）。 */
  readonly title: string
  /** 归属这个组的会话，按手工顺序。 */
  readonly sessionIds: readonly string[]
  /** ISO-8601。 */
  readonly createdAt: string
  readonly updatedAt: string
}

/**
 * 一次连接的完整状态。
 *
 * 三个集合一起给：组清单、已归档的会话、置顶的会话。分开取会让界面出现「组换了、
 * 置顶还是旧的」这种半新半旧的组合。
 */
export interface WorkspaceBaseline {
  readonly items: readonly WorkspaceView[]
  readonly archivedSessionIds: readonly string[]
  /** 最近置顶的在前。 */
  readonly pinnedSessionIds: readonly string[]
}

/** 组流的七种帧。`type` 是唯一的判别字段。 */
export type WorkspaceFollowFrame =
  | { readonly type: 'baseline'; readonly value: WorkspaceBaseline }
  | { readonly type: 'replace'; readonly value: WorkspaceBaseline }
  | { readonly type: 'upsert'; readonly workspace: WorkspaceView }
  | { readonly type: 'remove'; readonly workspaceId: string }
  | { readonly type: 'order'; readonly workspaceIds: readonly string[] }
  | { readonly type: 'archived'; readonly archivedSessionIds: readonly string[] }
  | { readonly type: 'pinned'; readonly pinnedSessionIds: readonly string[] }

/**
 * `workspace/follow` 的开流参数：**没有参数**。
 *
 * 组清单是进程级的、不分会话，所以这条流不带 `sessionId`。空对象是唯一合法的形状 ——
 * 多一个键就说明客户端以为它有参数，那种误解该在开流时就拒（`invalid-args`），
 * 而不是静默忽略、让它以为自己传对了。
 */
export type WorkspaceFollowArgs = Record<string, never>

/**
 * 组流的入参校验：只接受空对象。
 *
 * 与 `session/control` / `$events` 同一条规则（三条都是无参流），实现也只这一份 ——
 * `endpoints.ts` 的 `isEmptyArgs` 委托给它，两个 `Object.keys` 检查不会各漂一次。
 *
 * @param args - `payload.args`，任何值都可能来自对端。
 */
export function parseWorkspaceArgs(args: unknown): WorkspaceFollowArgs | undefined {
  if (typeof args !== 'object' || args === null || Array.isArray(args)) return undefined
  return Object.keys(args).length === 0 ? {} : undefined
}
