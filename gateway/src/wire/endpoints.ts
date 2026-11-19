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
 * ⚠️ 这里比旧的 `followRequestOf` 严格：旧实现对非法的 `maxMessages` **静默忽略**，
 * 这里判 `invalid-args`。静默忽略会让客户端的错误参数看起来「生效了」，而请求
 * 实际按缺省值发出去 —— 那是假绿的一种。
 */

import { isPositiveInteger, nonEmptyString } from './fields.ts'
import type { FollowRequest } from './mux.ts'

/** 三个端点名对应的泵。`events` 就是上游的 `$events`。 */
export type EndpointKind = 'follow' | 'events' | 'control'

/** 解析结果：认下来了（带泵种类与请求），或两种拒绝之一。 */
export type EndpointResolution =
  | { readonly ok: true; readonly kind: 'follow'; readonly request: FollowRequest }
  | { readonly ok: true; readonly kind: 'events' | 'control'; readonly request: undefined }
  | { readonly ok: false; readonly code: 'unknown-endpoint' | 'invalid-args' }

/** 三个端点名，按上游的写法原样 —— 这里是它们的**唯一定义处**。 */
export const ENDPOINTS = {
  follow: 'session/follow',
  control: 'session/control',
  events: '$events',
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
  if (endpoint === ENDPOINTS.control || endpoint === ENDPOINTS.events) {
    if (!isEmptyArgs(args)) return { ok: false, code: 'invalid-args' }
    return { ok: true, kind: endpoint === ENDPOINTS.events ? 'events' : 'control', request: undefined }
  }
  return { ok: false, code: 'unknown-endpoint' }
}

/** `follow` 的入参：会话名必需，窗口大小可缺省但给了就得是正整数。 */
function followArgsOf(args: unknown): FollowRequest | undefined {
  if (!isPlainObject(args)) return undefined
  const sessionId = nonEmptyString(args.sessionId)
  if (sessionId === undefined) return undefined
  if (args.maxMessages === undefined) return { sessionId }
  return isPositiveInteger(args.maxMessages) ? { sessionId, maxMessages: args.maxMessages } : undefined
}

/** 无入参的流：`args` 必须是空对象，多一个键都算说错了。 */
function isEmptyArgs(args: unknown): boolean {
  return isPlainObject(args) && Object.keys(args).length === 0
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
