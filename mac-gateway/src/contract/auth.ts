/**
 * 认证契约：三张票，各回答一个问题，泄漏一张不等于三张全丢
 * (docs/dev/plans/M4-identity-credentials.md §4.2)。
 *
 *   pairing code   一次性 · 10 分钟 · 错 5 次即作废 —— 建立关系；
 *                  只会得到 device token 作为回答
 *   device token   关系本身 · 长期有效 · 可吊销 —— 以 SHA-256 哈希存储；
 *                  只用于换取 access token
 *   access token   一段时间片 · 15 分钟 · 两端仅存内存 —— 唯一允许
 *                  随业务请求出行的票
 *
 * 纯函数，`random` 与 `now` 注入，因此每条规则都能离网断言。哈希用
 * `node:crypto` —— 本模块（位于 dsh 安装树之外）唯一允许的依赖 ——
 * 只存哈希，绝不存 token 本身。
 */

import { createHash } from 'node:crypto'

/** 一枚 access token 的存活时长。 */
export const ACCESS_TTL_MS = 15 * 60 * 1000

/** 配对码可在屏幕上停留多久，超时即失效。 */
export const PAIRING_TTL_MS = 10 * 60 * 1000

/** 配对码容忍多少次错误尝试，超过即提前作废。 */
export const PAIRING_MAX_ATTEMPTS = 5

/** 凭据文件的内容。吊销即重置为 `{ version: 1 }`。 */
export interface StoredCredentials {
  version: 1
  /** device token 的 SHA-256 十六进制。未配对时缺省。 */
  deviceTokenHash?: string
  /** 当前有效的配对码，已签发且未被消费时存在。 */
  pairing?: {
    code: string
    /** 纪元毫秒；届时即使未使用，配对码也作废。 */
    expiresAt: number
    /** 目前的错误尝试次数。 */
    attempts: number
  }
}

/** 空文件 —— 吊销后回到的状态。 */
export function emptyCredentials(): StoredCredentials {
  return { version: 1 }
}

/** 文本的 SHA-256 十六进制。确定性计算，无需注入随机源。 */
export function sha256Hex(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

/**
 * 6 位数字配对码：威胁是配对时在场的旁观者，而非在线暴力穷举 ——
 * 持久化的尝试上限才是真正的约束。
 */
export function newPairingCode(random: () => number): string {
  const value = Math.floor(random() * 1_000_000)
  return String(value).padStart(6, '0')
}

/** 32 随机字节的十六进制 —— device token 与 access token 同用这一形态。 */
export function newToken(random: () => number): string {
  let hex = ''
  for (let index = 0; index < 32; index += 1) {
    hex += Math.floor(random() * 256).toString(16).padStart(2, '0')
  }
  return hex
}

/**
 * `Authorization: Bearer <token>` → 取出 token；其余 → 无。头部是身份出行的
 * 唯一载体 (docs/dev/protocol.md §「身份」)——放进信封就会焊死在某一种
 * 传输上，违背第一条约束。
 */
export function bearerTokenOf(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  const match = /^Bearer\s+(\S+)$/.exec(header.trim())
  return match?.[1]
}

/** `code` 是否形似配对码。其余一律记为一次错误尝试。 */
export function isPlausiblePairingCode(code: unknown): code is string {
  return typeof code === 'string' && /^\d{6}$/.test(code)
}

/**
 * 一次配对尝试，输入输出都含文件 —— 留下的文件是判定的一部分，因为尝试
 * 计数与消费都是状态。配对码有三种死法：已消费、已过期（10 分钟）、
 * 已耗尽（5 次错误尝试，含畸形输入）。死码即移除 —— 它不再能被回答。
 */
export type PairingOutcome =
  | { status: 'paired'; file: StoredCredentials; deviceToken: string }
  | { status: 'invalid-code' | 'code-expired' | 'code-exhausted' | 'bad-code-shape'; file: StoredCredentials }

export function attemptPairing(
  file: StoredCredentials,
  code: unknown,
  now: number,
  random: () => number,
): PairingOutcome {
  const pairing = file.pairing

  if (pairing === undefined) return { status: 'invalid-code', file }
  if (!isPlausiblePairingCode(code)) {
    return countAttempt(file) // 畸形输入也算一次尝试
  }
  if (now >= pairing.expiresAt) {
    return { status: 'code-expired', file: withoutPairing(file) }
  }

  if (code !== pairing.code) {
    return countAttempt(file)
  }

  const deviceToken = newToken(random)
  return {
    status: 'paired',
    deviceToken,
    file: {
      version: 1,
      deviceTokenHash: sha256Hex(deviceToken),
      // 已消费：一次性属性靠移除来强制。
    },
  }
}

function countAttempt(file: StoredCredentials): PairingOutcome {
  const pairing = file.pairing
  if (pairing === undefined) return { status: 'invalid-code', file }
  const attempts = pairing.attempts + 1
  if (attempts >= PAIRING_MAX_ATTEMPTS) {
    return { status: 'code-exhausted', file: withoutPairing(file) }
  }
  return {
    status: 'invalid-code',
    file: { ...file, pairing: { ...pairing, attempts } },
  }
}

function withoutPairing(file: StoredCredentials): StoredCredentials {
  return { version: 1, ...(file.deviceTokenHash === undefined ? {} : { deviceTokenHash: file.deviceTokenHash }) }
}

/**
 * 凭已出示的 device token 签发一枚 access token。原始 token 只返回一次 ——
 * 服务端只留哈希，泄漏的凭据文件因此铸不出 access token。
 */
export function issueAccess(
  file: StoredCredentials,
  presentedDeviceToken: unknown,
  now: number,
  random: () => number,
): { status: 'ok'; token: string; tokenHash: string; expiresAt: number } | { status: 'denied' } {
  if (file.deviceTokenHash === undefined) return { status: 'denied' }
  if (typeof presentedDeviceToken !== 'string' || presentedDeviceToken === '') return { status: 'denied' }
  if (sha256Hex(presentedDeviceToken) !== file.deviceTokenHash) return { status: 'denied' }
  const token = newToken(random)
  return { status: 'ok', token, tokenHash: sha256Hex(token), expiresAt: now + ACCESS_TTL_MS }
}

/** 内存中的 access 记录在 `now` 时刻是否仍然有效。 */
export function isLiveAccess(record: { expiresAt: number } | undefined, now: number): boolean {
  return record !== undefined && now < record.expiresAt
}
