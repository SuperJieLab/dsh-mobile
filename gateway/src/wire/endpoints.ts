/**
 * 端点表：三个名字 → 泵的种类，以及各自的请求校验。
 *
 * 名字全部取自上游：`session/follow` 每个打开的会话一条，`session/control` 与
 * `$events` 每条连接各一条、且都没有入参。表是**唯一**的「名字 → 泵」判定处，
 * 帧在哪一格带这个名字由 `mux.ts` 的信封负责，两层不混。
 *
 * 两种失败分开：`unknown-endpoint`（名字不在表里 —— 两端说不到一处）与
 * `invalid-args`（名字对、内容不对 —— 同一处说错了东西）。排障时它们指向不同的一端。
 *
 * ⚠️ 这里比早先的实现严格：那一版对非法的 `maxMessages` **静默忽略**，
 * 这里判 `invalid-args`。静默忽略会让客户端的错误参数看起来「生效了」，而请求
 * 实际按缺省值发出去 —— 那是假绿的一种。
 */

import { isPositiveInteger, nonEmptyString, requestContainerOf } from './fields.ts'
import { parseWorkspaceArgs } from './workspace-stream.ts'


/** 解析结果：认下来了（带泵种类与请求），或两种拒绝之一。 */
export type EndpointResolution =
  | { readonly ok: true; readonly kind: 'follow'; readonly request: FollowRequest }
  | { readonly ok: true; readonly kind: 'events' | 'control' | 'workspace'; readonly request: undefined }
  | { readonly ok: false; readonly code: 'unknown-endpoint' | 'invalid-args' }

/**
 * 会话地址 —— 上游 `SessionAddress` 的判别联合。
 *
 * 本期只实现 `session` 一支，但**形状仍是带 `kind` 的联合**，不是裸 `sessionId`：
 * 将来加一种地址（`subagent`）时，改的是这一处判别，而不是每一个调用点的字段名。
 */
export interface SessionAddress {
  kind: 'session'
  sessionId: string
}

/**
 * `open` 载荷携带的 follow 请求 —— **上游 `SessionFollowRequest` 逐字**。
 *
 * 网关不再按自己的目标重算窗口（那一版把 `maxMessages` 乘二、`minTurns` 改成 1，
 * 于是同一屏在手机与 Web UI 上长度不同）。这里收到的就是宿主方法的实参，原样交出去；
 * 缺省的键也**不补** —— 补一个宿主没要的默认值，就是第二份窗口规则。
 */
export interface FollowRequest {
  address: SessionAddress
  maxMessages?: number
  turnWindow?: { minMessages: number; minTurns: number }
  /** 打开即激活会话（宿主的 `promote`）；缺省留作被动观察。 */
  activate?: boolean
  assistantStream?: true
}

/**
 * 四个端点名，按上游的写法原样 —— 这里是它们的**唯一定义处**。
 *
 * 三条无参（`session/control`、`$events`、`workspace/follow`），一条按会话
 * （`session/follow`）。前三条的入参校验是同一件事：空对象，多一个键都算说错了。
 */
export const ENDPOINTS = {
  follow: 'session/follow',
  control: 'session/control',
  events: '$events',
  workspace: 'workspace/follow',
} as const

/**
 * 把一个端点名与它的入参解析成开流请求。
 *
 * @param endpoint - `open` 帧顶层的那一格，任何值都可能来自对端。
 * @param args - `payload.args`；上游的端点方法从这里取参数，所以它是**容器**而不是参数本身。
 */
export function resolveEndpoint(endpoint: unknown, args: unknown): EndpointResolution {
  if (endpoint === ENDPOINTS.follow) {
    const request = followArgsOf(args)
    return request === undefined ? { ok: false, code: 'invalid-args' } : { ok: true, kind: 'follow', request }
  }
  if (endpoint === ENDPOINTS.workspace) {
    return isEmptyArgs(args)
      ? { ok: true, kind: 'workspace', request: undefined }
      : { ok: false, code: 'invalid-args' }
  }
  if (endpoint === ENDPOINTS.control || endpoint === ENDPOINTS.events) {
    if (!isEmptyArgs(args)) return { ok: false, code: 'invalid-args' }
    return { ok: true, kind: endpoint === ENDPOINTS.events ? 'events' : 'control', request: undefined }
  }
  return { ok: false, code: 'unknown-endpoint' }
}

/**
 * `follow` 的入参：宿主的形参是一个 `request` 对象，所以线上也多一层同名容器。
 *
 * 可缺省的四个键只在**出现**时校验：给了就得是那个类型（畸形参数拒掉，
 * 不静默退化 —— 退化的表现是「看起来生效了」而请求按缺省值发出去）。没给就**不补**：
 * 宿主自己有一份默认值，网关再补一份就是第二个来源。
 */
function followArgsOf(args: unknown): FollowRequest | undefined {
  if (!isPlainObject(args)) return undefined
  const request = requestContainerOf(args)
  if (request === undefined) return undefined
  const address = sessionAddressOf(request.address)
  if (address === undefined) return undefined

  const follow: FollowRequest = { address }
  if ('maxMessages' in request) {
    if (!isPositiveInteger(request.maxMessages)) return undefined
    follow.maxMessages = request.maxMessages
  }
  if ('turnWindow' in request) {
    const turnWindow = turnWindowOf(request.turnWindow)
    if (turnWindow === undefined) return undefined
    follow.turnWindow = turnWindow
  }
  if ('activate' in request) {
    if (typeof request.activate !== 'boolean') return undefined
    follow.activate = request.activate
  }
  if ('assistantStream' in request) {
    // 上游把它声明成字面量 `true`：“要”就写 true，不要就省略。`false` 不在集合里。
    if (request.assistantStream !== true) return undefined
    follow.assistantStream = true
  }
  return follow
}

/** 会话地址：`kind` 只认 `session`，`sessionId` 必须是非空字符串。 */
function sessionAddressOf(value: unknown): SessionAddress | undefined {
  if (!isPlainObject(value)) return undefined
  if (value.kind !== 'session') return undefined
  const sessionId = nonEmptyString(value.sessionId)
  return sessionId === undefined ? undefined : { kind: 'session', sessionId }
}

/** 翻页窗口的两个下限：都必须是正整数，缺一个就整格不成形。 */
function turnWindowOf(value: unknown): { minMessages: number; minTurns: number } | undefined {
  if (!isPlainObject(value)) return undefined
  if (!isPositiveInteger(value.minMessages) || !isPositiveInteger(value.minTurns)) return undefined
  return { minMessages: value.minMessages, minTurns: value.minTurns }
}

/**
 * 无入参的流：`args` 必须是空对象，多一个键都算说错了。
 *
 * 委托给 `workspace-stream.ts` 的 `parseWorkspaceArgs` —— 三条无参流共用一次判定。
 * 两份 `Object.keys` 检查迟早各漂一次，而漂了不会有编译错误。
 */
function isEmptyArgs(args: unknown): boolean {
  return parseWorkspaceArgs(args) !== undefined
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
