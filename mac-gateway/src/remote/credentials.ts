/**
 * 凭据适配器：持有三张票状态的保险库。所有*规则*都在 `contract/auth.ts`；
 * 本模块只管状态与 I/O —— 凭据文件与内存中的 access token 活跃表。
 *
 * 读侧 fail-closed：读不了或解析不了的文件按未配对待（最坏重配一次，
 * 绝不出现意外的授权）。写侧尽力而为但绝不静默：持久化失败会记日志，
 * 关系在本运行内仍然可用，只是活不过重启 —— 直接拒绝等于因磁盘不可写
 * 而否定一次有效配对。
 *
 * access 表刻意放内存：15 分钟的票不必活过重启，客户端的刷新流程让
 * 重签一枚票成为不可见的无事
 * （docs/dev/plans/M4-identity-credentials.md §3.3）。
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.http)
import {
  attemptPairing,
  bearerTokenOf,
  emptyCredentials,
  isLiveAccess,
  issueAccess,
  newPairingCode,
  PAIRING_TTL_MS,
  sha256Hex,
  type StoredCredentials,
} from '../contract/auth.ts'

/** 无特别指定时凭据文件的所在。 */
export const DEFAULT_CREDENTIALS_PATH = join(homedir(), '.dsh', 'dsh-mobile', 'credentials.json')

export class CredentialVault {
  private file: StoredCredentials = emptyCredentials()
  /** 按哈希索引的活跃 access token；原始 token 绝不存于服务端。 */
  private readonly access = new Map<string, { expiresAt: number }>()

  // 显式字段而非 TypeScript 参数属性：Node 的类型剥离模式执行不了它们，
  // 本包零构建。
  private readonly path: string
  private readonly random: () => number
  private readonly now: () => number

  constructor(
    path: string = DEFAULT_CREDENTIALS_PATH,
    random: () => number = Math.random,
    now: () => number = Date.now,
  ) {
    this.path = path
    this.random = random
    this.now = now
    this.load()
  }

  /** 读文件；任何读不了的都按未配对待 —— fail closed。 */
  private load(): void {
    try {
      const raw = readFileSync(this.path, 'utf8')
      const parsed = JSON.parse(raw) as StoredCredentials
      if (parsed?.version === 1) {
        this.file = parsed
      } else {
        this.file = emptyCredentials()
      }
    } catch {
      // 缺失或损坏：无论哪种都是未配对的保险库 —— 下一次 `pairingCode()`
      // 会签发新码。
      this.file = emptyCredentials()
    }
  }

  private persist(): void {
    try {
      mkdirSync(dirname(this.path), { recursive: true })
      writeFileSync(this.path, `${JSON.stringify(this.file, null, 2)}\n`, 'utf8')
    } catch (error) {
      log.error(`could not persist credentials: ${String(error)}`)
    }
  }

  /**
   * 要显示在屏幕上的配对码：没有、或旧的已死时签发一枚新的 ——
   * 已经无法被回答的码不得继续展示。
   */
  pairingCode(): string {
    const now = this.now()
    const pairing = this.file.pairing
    if (pairing !== undefined && now < pairing.expiresAt) return pairing.code
    this.file = {
      ...this.file,
      pairing: {
        code: newPairingCode(this.random),
        expiresAt: now + PAIRING_TTL_MS,
        attempts: 0,
      },
    }
    this.persist()
    return this.file.pairing!.code
  }

  /** 消费一次配对尝试。失败时 `reason` 是人类可读的拒绝理由。 */
  pair(code: unknown): { ok: true; deviceToken: string } | { ok: false; reason: string } {
    const outcome = attemptPairing(this.file, code, this.now(), this.random)
    this.file = outcome.file
    this.persist()
    if (outcome.status === 'paired') return { ok: true, deviceToken: outcome.deviceToken }
    const reasons: Record<Exclude<typeof outcome.status, 'paired'>, string> = {
      'invalid-code': '配对码不对。',
      'code-expired': '配对码已过期 —— 在 Mac 上取一个新的。',
      'code-exhausted': '错太多次，配对码已作废 —— 在 Mac 上取一个新的。',
      'bad-code-shape': '配对码应当是 6 位数字。',
    }
    return { ok: false, reason: reasons[outcome.status] }
  }

  /** 用 device token 换一枚 access token。被拒即关系不存在。 */
  refresh(deviceToken: unknown): { ok: true; accessToken: string; expiresAt: number } | { ok: false } {
    const outcome = issueAccess(this.file, deviceToken, this.now(), this.random)
    if (outcome.status === 'denied') return { ok: false }
    this.access.set(outcome.tokenHash, { expiresAt: outcome.expiresAt })
    return { ok: true, accessToken: outcome.token, expiresAt: outcome.expiresAt }
  }

  /** HTTP/WS 闸门：该 `Authorization` 头是否指向一枚活跃的 access token？ */
  authenticate(authorizationHeader: string | undefined): boolean {
    const token = bearerTokenOf(authorizationHeader)
    if (token === undefined) return false
    return isLiveAccess(this.access.get(sha256Hex(token)), this.now())
  }

  /**
   * 不经配对码预配对 —— 仅装配测试。生产配对走 `pairingCode()` + `pair()`；
   * 本方法直接写入关系，测试因此能持有原始 token 而不必解析控制台输出。
   */
  seedDeviceToken(deviceToken: string): void {
    this.file = { version: 1, deviceTokenHash: sha256Hex(deviceToken) }
    this.access.clear()
    this.persist()
  }
}
