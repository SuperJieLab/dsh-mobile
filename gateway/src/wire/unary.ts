/**
 * 一元调用的信封与端点名：两端共守的形状。
 *
 * 形状逐字照上游 Web UI 的 Connection RPC：请求是 `client-request`，应答是
 * `server-response`，参数在 `payload.args` 这一格容器里，失败的三个键恒定。
 * **没有版本字段** —— 上游没有；旧客户端连新网关靠「端点不存在」发现。
 *
 * 这一层只管「一条消息的壳长什么样、怎么从字节里读出来」。哪个名字由谁处理、
 * 参数合不合法，是 `protocol/` 的事 —— 分开放的理由：名字与处理器住在 `protocol/`，
 * 而 `wire/` 不许认识它们（`structure.test.ts` 的「wire/ does not reach outside itself」）。
 *
 * 端点名分两片：照上游的七个（`session/modelCatalog` 等）与我们自造的九个
 * （一律挂 `mobile/`）。分开是为了将来对齐时知道该搬哪些 —— 混用上游命名空间会让
 * 「同名不同义」写进契约，读上游文档的人会读错。
 */

import { nonEmptyString } from './fields.ts'

/**
 * 我们开的一元端点名，两段式。
 *
 * 前七个与上游逐字一致（参数与返回内容仍是我们的，见方案 1.1 的映射表）；
 * 其余挂在 `mobile/` 下：五个「上游只有近似端点」、两个「上游没有」、以及两条鉴权。
 */
export type UnaryEndpointName =
  | 'session/modelCatalog'
  | 'session/selectModel'
  | 'session/create'
  | 'session/prompt'
  | 'commands/list'
  | 'commands/execute'
  | 'workspace/delete'
  | 'session/list'
  | 'mobile/snapshot'
  | 'mobile/page'
  | 'permissionPresets/catalog'
  | 'mobile/workspaceCreate'
  | 'mobile/approvalAnswer'
  | 'mobile/questionAnswer'
  | 'mobile/pair'
  | 'mobile/refresh'

/** 同一批名字的运行时视图 —— 路由查表与测试共用一份，不再手抄第二遍。 */
export const UNARY_ENDPOINT_NAMES: readonly UnaryEndpointName[] = [
  'session/modelCatalog',
  'session/selectModel',
  'session/create',
  'session/prompt',
  'commands/list',
  'commands/execute',
  'workspace/delete',
  'session/list',
  'mobile/snapshot',
  'mobile/page',
  'permissionPresets/catalog',
  'mobile/workspaceCreate',
  'mobile/approvalAnswer',
  'mobile/questionAnswer',
  'mobile/pair',
  'mobile/refresh',
]

/** 一次一元调用的请求。 */
export interface ClientRequest {
  readonly type: 'client-request'
  /** 客户端造、网关原样回；只用于把应答对回请求与串日志，不参与判定。 */
  readonly rpcId: string
  /** 端点名，两段。必须与 URL 末两段相同 —— 这一致性由传输层判，这里只带出来。 */
  readonly method: string
  /** 参数容器：上游的端点方法从 `args` 取参数，不是从载荷本身取。 */
  readonly payload: { readonly args: Readonly<Record<string, unknown>> }
}

/** 一次失败的三格。`details` 恒为对象，没有结构化信息时给 `{}`。 */
export interface RemoteFailure {
  readonly code: string
  readonly message: string
  readonly details: Readonly<Record<string, unknown>>
}

/** 一次调用的结果：成功带 `value`，失败带三格错误。 */
export type RemoteResult<T = unknown> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: RemoteFailure }

/** 网关回给客户端的外壳。 */
export interface ServerResponse<T = unknown> {
  readonly type: 'server-response'
  readonly rpcId: string
  readonly result: RemoteResult<T>
}

const REQUEST_KEYS = new Set(['type', 'rpcId', 'method', 'payload'])

/**
 * 从线上文本解析一条一元请求的**外壳**。
 *
 * 逐格严格：四条都要在、不能多（残留的 `v` 会被拒），`payload` 只能有 `args`、
 * 且 `args` 必须是普通对象。严格是刻意的 —— 「多一格」与「少一格」在宽松解析下
 * 都表现为「读得到」，只有逐格对账才分得出来，而它们指向的故障完全不同：
 * 多一格是对端还在说旧协议，少一格是这条请求坏了。
 *
 * @returns 归不上任何端点时返回 `undefined`；是否认得 `method` 由 `protocol/` 判。
 */
export function parseClientRequest(text: string): ClientRequest | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined
  const body = parsed as Record<string, unknown>

  const keys = Object.keys(body)
  if (keys.length !== REQUEST_KEYS.size) return undefined
  for (const key of keys) if (!REQUEST_KEYS.has(key)) return undefined

  if (body.type !== 'client-request') return undefined
  // `rpcId` 只用于对日志，**不校验格式也不要求非空**：空串照收（客户端没有可用 id 时
  // 就发空串），网关按空串记。`method` 不同 —— 它要与路径比对，空的等于没说是哪条端点。
  if (typeof body.rpcId !== 'string') return undefined
  const rpcId = body.rpcId
  const method = nonEmptyString(body.method)
  if (method === undefined) return undefined

  if (typeof body.payload !== 'object' || body.payload === null || Array.isArray(body.payload)) {
    return undefined
  }
  const payload = body.payload as Record<string, unknown>
  const payloadKeys = Object.keys(payload)
  if (payloadKeys.length !== 1 || payloadKeys[0] !== 'args') return undefined

  const args = payload.args
  if (typeof args !== 'object' || args === null || Array.isArray(args)) return undefined

  return { type: 'client-request', rpcId, method, payload: { args: args as Record<string, unknown> } }
}

/** 把结果包成应答外壳并序列化。键序固定，供两端共守的样本逐字比对。 */
export function encodeServerResponse<T>(rpcId: string, result: RemoteResult<T>): string {
  return JSON.stringify({ type: 'server-response', rpcId, result })
}
