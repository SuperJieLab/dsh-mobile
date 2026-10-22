/**
 * 上游的会话列表事件 → 我们的行变更。
 *
 * **全仓唯一认识 `api-session/added` 这类名字与它字段位置的地方。** 手机端看不见
 * 上游形状（`ports/events.ts` 的立场），所以翻译必须在这里完成：客户端只认
 * `SessionListChange` 的四支。
 *
 * 参数位置是上游 `ctx.emit('api-session/status', id, running)` 式的**位置参数**，
 * 不是对象 —— 认错一位就是静默错值。故每一支都判那几位的位置与类型，任何一位不对就
 * 当作「认不出」，由泵原样转发（在那里没有听众，等于丢弃）。
 *
 * 两处宽松是有意的：`added` 的 `running` / `blank` 按 `=== true` 取（上游把布尔写成
 * 别的类型时，行落到「没在跑 / 不是候补」—— 两个都是保守值），`title` 走 `titleOf`
 * （非字符串一律当缺席）。其余各支是严格判型。
 *
 * 与列表路径同源：标题都走 `titleOf`，所以「无标题」在两条路上是同一条判定。
 */
import type { SessionListChange, SessionListRow } from '../wire/session-events.ts'
import { nonEmptyString } from '../wire/fields.ts'
import { titleOf, type ProjectionValues } from './sessions.ts'

/** 上游 `api-session/added` 携带的 `SessionSummary` 里我们读的那几个字段。 */
interface HostSummaryLike {
  readonly sessionId?: unknown
  readonly updatedAt?: unknown
  readonly running?: unknown
  readonly blank?: unknown
  readonly origin?: unknown
  readonly projections?: unknown
}

/**
 * 一条上游事件 → 一条列表变更；认不出返回 `undefined`。
 *
 * `args` 收 `unknown` 而不是 `readonly unknown[]`：上游的声明是数组，但**声明准确**
 * 与**这一层不崩**是两件事 —— 协议被破坏时这里该返回「认不出」，而不是让一个
 * 下标访问抛出去把整条事件泵带走。
 *
 * @param event - 上游事件名（`api-session/added` 等）。
 * @param args - 上游 `emit` 的位置参数。
 */
export function sessionListChangeOf(event: string, args: unknown): SessionListChange | undefined {
  if (!Array.isArray(args)) return undefined
  switch (event) {
    case 'api-session/added': {
      const row = sessionListRowOf(args[0])
      return row === undefined ? undefined : { kind: 'added', row }
    }
    case 'api-session/removed': {
      const id = nonEmptyString(args[0])
      return id === undefined ? undefined : { kind: 'removed', id }
    }
    case 'api-session/status': {
      const id = nonEmptyString(args[0])
      const running = args[1]
      if (id === undefined || typeof running !== 'boolean') return undefined
      return { kind: 'status', id, running }
    }
    case 'api-session/activity': {
      const id = nonEmptyString(args[0])
      const updatedAt = args[1]
      if (id === undefined || typeof updatedAt !== 'number' || !Number.isFinite(updatedAt)) return undefined
      return { kind: 'activity', id, updatedAt }
    }
    default:
      return undefined
  }
}

/**
 * 上游的一份 `SessionSummary` → 我们的一行。
 *
 * `createdAt` 刻意不取：上游 summary 不带它，而为了填这一格去查会话头会把 I/O
 * 拉进事件路径。
 */
export function sessionListRowOf(summary: unknown): SessionListRow | undefined {
  if (typeof summary !== 'object' || summary === null) return undefined
  const host = summary as HostSummaryLike
  const id = nonEmptyString(host.sessionId)
  const updatedAt = host.updatedAt
  if (id === undefined || typeof updatedAt !== 'number' || !Number.isFinite(updatedAt)) return undefined
  const origin = nonEmptyString(host.origin)
  return {
    id,
    ...titleOf(projectionValuesOf(host.projections)),
    updatedAt,
    running: host.running === true,
    blank: host.blank === true,
    ...(origin === undefined ? {} : { origin }),
  }
}

/**
 * 事件里的投影块 → 投影值的表。
 *
 * 只看 `values`：`kind` 的两档（`sequenced` / `cached`）描述的是「这块值该按什么
 * 优先级与历史合并」，而列表行只取当前值，两档在这一处没有区别。
 */
function projectionValuesOf(projections: unknown): ProjectionValues | undefined {
  if (typeof projections !== 'object' || projections === null) return undefined
  const values = (projections as { values?: unknown }).values
  if (typeof values !== 'object' || values === null) return undefined
  return values as ProjectionValues
}
