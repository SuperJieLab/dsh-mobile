/**
 * 认证契约：三张票，各回答一个问题，泄漏一张不等于三张全丢
 * (M4 §4.2)。
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

/**
 * 上一枚 device token 还能换票的时长 —— 轮换留下的那条回头路。
 *
 * 轮换的目的是「让同时存在的第二个使用者暴露出来」，而不是「让客户端一崩就失联」。
 * 客户端收到新凭证是同步写盘，但「收到之后、写盘之前被杀」永远可能发生 —— 那台手机
 * 重启后读到的还是旧凭证。宽限让它还能换一次票、拿到新凭证，自己走回来。
 *
 * 取 24 小时：短于这个数会让「手机没电一天」变成「必须重新配对」，而那个代价落在
 * 唯一一个正常用户身上；长于它则让泄漏方多活一天。失窃检测本来就不靠这里 ——
 * 它靠的是「旧凭证被用了」这条日志。
 */
export const DEVICE_ROTATION_GRACE_MS = 24 * 60 * 60 * 1000

/** 凭据文件的内容。吊销即重置为 `{ version: 1 }`。 */
export interface StoredCredentials {
  version: 1
  /** device token 的 SHA-256 十六进制。未配对时缺省。 */
  deviceTokenHash?: string
  /**
   * 上一枚 device token 的哈希与它失效的时刻 —— 轮换的回头路。
   *
   * 只存一枚：两个使用者交替换票时，每一次轮换都会把「刚用过的那个」推进这里，
   * 另一个因此在下一次被拒。那正是「同一层关系被两台设备用」的暴露方式。
   */
  previous?: { hash: string; until: number }
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
 * 唯一载体 —— 放进信封就会焊死在某一种传输上，而身份是传输的属性、
 * 不是消息的属性。
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
  return {
    version: 1,
    ...(file.deviceTokenHash === undefined ? {} : { deviceTokenHash: file.deviceTokenHash }),
    ...(file.previous === undefined ? {} : { previous: file.previous }),
  }
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
): {
  status: 'ok'
  token: string
  tokenHash: string
  expiresAt: number
  /** 出示的是**上一枚**凭证（轮换的宽限里那条路）。调用方据此记一条「关系可能被共用」。 */
  viaPrevious: boolean
} | { status: 'denied' } {
  if (typeof presentedDeviceToken !== 'string' || presentedDeviceToken === '') return { status: 'denied' }
  const hash = sha256Hex(presentedDeviceToken)
  const current = file.deviceTokenHash !== undefined && hash === file.deviceTokenHash
  const previous = file.previous !== undefined && file.previous.hash === hash && now < file.previous.until
  if (!current && !previous) return { status: 'denied' }
  const token = newToken(random)
  return {
    status: 'ok', token, tokenHash: sha256Hex(token), expiresAt: now + ACCESS_TTL_MS,
    viaPrevious: previous,
  }
}

/**
 * 换一枚新的 device token：新的上台，**刚用过的那个**进宽限。
 *
 * 只保留一枚旧凭证是有意的：两个使用者交替换票时，每次轮换都把另一个挤掉，
 * 它下一次换票就被拒 —— 那台设备于是暴露（并且掉线）。误判的代价是「同一台手机
 * 上有两个实例」，而那种情况本来就不该发生。
 */
export function rotateDeviceToken(
  file: StoredCredentials,
  now: number,
  random: () => number,
): { file: StoredCredentials; deviceToken: string } {
  const deviceToken = newToken(random)
  const replaced = file.deviceTokenHash
  return {
    file: {
      ...file,
      deviceTokenHash: sha256Hex(deviceToken),
      // 进宽限的是**被替换掉的那一枚**，不是刚出示的那一枚：后者可能本来就是
      // 宽限里那条回头路，把它再存一遍等于让那条路永不关闭。
      previous: replaced === undefined
        ? undefined
        : { hash: replaced, until: now + DEVICE_ROTATION_GRACE_MS },
    },
    deviceToken,
  }
}

/** 内存中的 access 记录在 `now` 时刻是否仍然有效。 */
export function isLiveAccess(record: { expiresAt: number } | undefined, now: number): boolean {
  return record !== undefined && now < record.expiresAt
}
