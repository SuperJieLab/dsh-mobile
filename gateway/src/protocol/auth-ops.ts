/**
 * 两条**凭据在体内**的 op：`pair` 与 `refresh`。
 *
 * 它们不在 `handle` 里 —— 那一条链上的一切都要先过头部那道 access token 闸，而这两条
 * 恰恰是用来**拿票**的：先有鸡还是先有蛋这件事不在 `handle` 里解，在闸门旁边解。
 *
 * 判定住这里：分发、四种配对失败的措辞、被拒时信封里的 code。传输层只剩三件事 ——
 * 读体、调这里、把 `ok` 映射成状态码。**「401」不在本模块出现**：那是承载的说法，
 * 协议只说「这条没成」。
 */

import type { PairRequest, PairResponse, RefreshRequest, RefreshResponse } from '../wire/auth.ts'
import type { RemoteResult } from '../wire/unary.ts'
import { refused, unwrap } from './rpc.ts'

/**
 * 本模块要的两件本事 —— 由凭据库实现，结构上即可（不需要适配器）。
 *
 * 刻意不 import `CredentialVault`：那样协议层就认识了一个住在 `remote/` 的类型，
 * 而「判定不依赖传输」正是把这段从传输层搬出来的理由。
 */
export interface AuthPort {
  pair(code: unknown): { ok: true; deviceToken: string } | { ok: false; reason: string }
  refresh(deviceToken: unknown): {
    ok: true
    accessToken: string
    expiresAt: number
    deviceToken: string
  } | { ok: false }
}

/**
 * 应答一条 `pair` / `refresh`。
 *
 * @returns 协议信封。`ok: false` 的两条都是认证失败，承载方据此选状态码 ——
 *   它不需要再判一次「为什么失败」，那是这里的职责。
 */
export function handleAuthOp(
  op: 'pair' | 'refresh',
  message: unknown,
  port: AuthPort,
): PairResponse | RefreshResponse {
  // 字段名从请求形状里取：改名会在这里编译失败，而不是让客户端与服务端各读一个名字、
  // 每次配对都落到 `bad-code-shape`。两者都可能缺 —— 缺了交给规则层拒绝，
  // 所以读取处按 `unknown` 收窄。
  //
  // 不写成 `Partial<PairRequest & RefreshRequest>`：两条 op 的 `op` 是互斥字面量，
  // 交叉之后整个类型塌成 `never`。
  const payload = message as {
    code?: PairRequest['code']
    deviceToken?: RefreshRequest['deviceToken']
  }

  return unwrap(op === 'pair' ? pairOf(payload.code, port) : refreshOf(payload.deviceToken, port))
}

/** `pair` 的业务字段。两条路径共用一份判定 —— 措辞与码都不抄第二遍。 */
export function pairOf(code: unknown, port: AuthPort): RemoteResult {
  const outcome = port.pair(code)
  if (!outcome.ok) {
    // 四种失败原因的措辞逐字来自规则层 —— 这一层只把它搬进信封。
    return refused('invalid-pairing-code', outcome.reason)
  }
  return { ok: true, value: { deviceToken: outcome.deviceToken } }
}

/** `refresh` 的业务字段。 */
export function refreshOf(deviceToken: unknown, port: AuthPort): RemoteResult {
  const outcome = port.refresh(deviceToken)
  if (!outcome.ok) {
    return refused('unauthenticated', 'unknown device token — pair again')
  }
  return {
    ok: true,
    value: {
      accessToken: outcome.accessToken,
      expiresAt: outcome.expiresAt,
      deviceToken: outcome.deviceToken,
    },
  }
}
