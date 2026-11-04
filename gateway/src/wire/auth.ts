/**
 * 两端共守的凭据类 op 形状。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift` 的 `PairRequest` /
 * `RefreshRequest` / `PairResponse` / `RefreshResponse`）—— 改字段那边必须同改。
 *
 * 这两条 op 走同一个 `POST /rpc`，但它们的凭据在**体内**而不是头部：配对时还没有
 * 票，换票时拿着的是那张不能出行的 device token。这也是它们绕过统一请求入口的原因
 * （其余 op 由 `protocol/rpc.ts` 的 `handle` 分派）。
 *
 * **这里只有形状，没有校验。** 校验在 `protocol/auth.ts` 的规则里 ——
 * `attemptPairing` 会区分四种失败（码不对 / 已过期 / 错太多次 / 形状不是 6 位数字），
 * 最后那条正是为了让用户在手机上看到「配对码应当是 6 位数字」。在这里加一层严格
 * 解析会把那条原因换成笼统的 `invalid-request`，那是行为变化。
 *
 * 所以读的时候仍然按 `unknown` 取字段：形状说的是「一条**良构**报文长什么样」，
 * 而校验良构不在这里 —— 别把这两件事读成一件。
 */

import type { WireError } from './rpc.ts'

/** 配对码就是这条消息的载荷。 */
export interface PairRequest {
  v: number
  op: 'pair'
  code: string
}

/** 续期：设备凭证换访问凭证。 */
export interface RefreshRequest {
  v: number
  op: 'refresh'
  deviceToken: string
}

/** 配对回包：设备凭证只在这里出现一次。 */
export interface PairResponse {
  v: number
  ok: boolean
  error?: WireError
  deviceToken?: string
}

/** 续期回包：访问凭证、它到期的时刻（epoch 毫秒），以及轮换后的设备凭证。 */
export interface RefreshResponse {
  v: number
  ok: boolean
  error?: WireError
  accessToken?: string
  expiresAt?: number
  /**
   * 轮换后的设备凭证 —— 客户端**必须**存下它。
   *
   * 服务端每次续期都换一枚：旧的在宽限期内还能用一次，过期即作废。客户端丢掉这个字段
   * 不会立刻坏，但会掉进宽限那条回头路，而且下一次轮换之后就再也回不来了。
   */
  deviceToken?: string
}
