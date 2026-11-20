/**
 * 两条**凭据在体内**的端点：`mobile/pair` 与 `mobile/refresh`。
 *
 * 它们标着 `unauthenticated` —— 端点表上的一切都要先过头部那道 access token 闸，
 * 而这两条恰恰是用来**拿票**的。要求「拿票的端点先有票」是死锁，症状是「全新的
 * 手机永远配不上对」，所以闸门对它们放行（判断在 `remote/http.ts`，标记在表里）。
 *
 * 判定住这里：四种配对失败的措辞、被拒时信封里的 code。**「401」不在本模块出现**：
 * 那是承载的说法，协议只说「这条没成」。
 */

import type { RemoteResult } from '../wire/unary.ts'
import { refused } from './rpc.ts'

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
