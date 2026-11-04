/**
 * 会话列表的**事件**形状 —— 与 `rpc.ts` 的列表行同源，但这两件事分开声明：
 * 列表行是「一次拉取的一行」，这里是「一条变更」。合在一起会让「拉取」与「增量」
 * 两个路径共用一个类型，而它们对字段的要求本来就不同（事件没有 `createdAt`）。
 *
 * 与 `mux.ts` 的 `MuxApprovalWaterfall` 同层同手法：载荷按 `kind` 分派的联合，
 * 客户端穷举分派、认不出的默认丢弃。**它是契约**，改字段两端必须同改。
 */

/**
 * 一条变更携带的行。字段是列表行的子集 —— 事件里**没有** `createdAt`：
 * 上游 `SessionSummary` 不带它（带的是 `formatStatus` 与 `cwd`，两者我们都不发），
 * 而为了填这一格去查一次会话头会把 I/O 拉进事件路径。
 */
export interface SessionListRow {
  id: string
  /** 缺席 = 无标题或投影不可用 —— 与列表路径同一条判定，不是空串。 */
  title?: string
  updatedAt: number
  running: boolean
  blank: boolean
  origin?: string
  /** 所属工作空间；不属于任何工作空间时整个字段缺席 —— 与列表行同义。 */
  workspaceId?: string
}

/** 会话列表的一条增量。四种，各自对应上游的一类事件。 */
export type SessionListChange =
  | { kind: 'added'; row: SessionListRow }
  | { kind: 'removed'; id: string }
  | { kind: 'status'; id: string; running: boolean }
  | { kind: 'activity'; id: string; updatedAt: number }
