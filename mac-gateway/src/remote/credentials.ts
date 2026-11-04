/**
 * 凭据适配器：持有三张票状态的保险库。所有*规则*都在 `protocol/auth.ts`；
 * 本模块只管状态与 I/O —— 凭据文件与内存中的 access token 活跃表。
 *
 * 读侧 fail-closed：读不了或解析不了的文件按未配对待（最坏重配一次，
 * 绝不出现意外的授权）。写侧尽力而为但绝不静默：持久化失败会记日志，
 * 关系在本运行内仍然可用，只是活不过重启 —— 直接拒绝等于因磁盘不可写
 * 而否定一次有效配对。
 *
 * access 表刻意放内存：15 分钟的票不必活过重启，客户端的刷新流程让
 * 重签一枚票成为不可见的无事
 * （M4 §3.3）。
 */

import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
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
  rotateDeviceToken,
  sha256Hex,
  type StoredCredentials,
} from '../protocol/auth.ts'

/** 无特别指定时凭据文件的所在。 */
export const DEFAULT_CREDENTIALS_PATH = join(homedir(), '.dsh', 'dsh-mobile', 'credentials.json')

/**
 * 凭据文件的载荷版本。**加字段就加一**，并在 {@link CREDENTIAL_MIGRATIONS} 里补一步。
 * 必须与 `StoredCredentials.version` 的字面量一致。
 */
export const CREDENTIALS_VERSION = 1

/** 一步迁移：把来源版本的文件变成下一版。迁不动返回 `undefined`。 */
export type CredentialMigration = (
  file: Record<string, unknown>,
) => Record<string, unknown> | undefined

/**
 * 每一步把**来源版本**的文件变成下一版。键是来源版本。
 *
 * 现在是空的 —— 凭据只有一版。空表不是「没有迁移」，是「还没发生过迁移」：
 * 加 v2 时往这里补一步，老用户就不用重新配对。
 */
export const CREDENTIAL_MIGRATIONS: Record<number, CredentialMigration> = {}

/**
 * 把文件迁到 `target`（默认当前版本）。
 *
 * **迁不动就返回 `undefined`**，由调用方按未配对待 —— 不猜。凭据猜错的代价不是
 * 「显示不对」，是「认证行为诡异」：把一份不认识的格式当 v1 读，读出来的哈希可能是错的。
 */
export function migrateCredentials(
  file: Record<string, unknown>,
  steps: Record<number, CredentialMigration> = CREDENTIAL_MIGRATIONS,
  target: number = CREDENTIALS_VERSION,
): Record<string, unknown> | undefined {
  let current = file
  let version = typeof current.version === 'number' ? current.version : 0
  if (version > target) return undefined

  while (version < target) {
    const step = steps[version]
    if (step === undefined) return undefined
    const next = step(current)
    if (next === undefined) return undefined
    current = next
    version += 1
  }
  return current
}

export class CredentialVault {
  private file: StoredCredentials = emptyCredentials()
  /** 按哈希索引的活跃 access token；原始 token 绝不存于服务端。 */
  private readonly access = new Map<string, { expiresAt: number }>()

  // 显式字段而非 TypeScript 参数属性：Node 的类型剥离模式执行不了它们，
  // 本包零构建。
  private readonly path: string
  private readonly random: () => number
  private readonly now: () => number
  /**
   * 上一次读或写这个文件时的指纹（`mtime:size`）。`undefined` = 那时它不存在。
   *
   * 存在的理由只有一个：**撤销要立刻生效**。删掉凭据文件是唯一的撤销手段，而
   * 读盘若只发生在构造时，删了文件进程仍认着内存里那份关系，手里那枚 access 票
   * 也还能用满 15 分钟。指纹比对让「删文件」在下一个请求上就生效。
   */
  private stamp: string | undefined

  /**
   * 读文件时用的迁移链。默认是当前版本那一套；可注入是为了让「接线对不对」能被断言 ——
   * 迁移表在生产里现在是空的（凭据只有一版），不注入的话循环体永远跑不到，
   * 「接没接上」这件事没有任何判据看得见。
   */
  private readonly migrations: { steps: Record<number, CredentialMigration>; target: number }

  constructor(
    path: string = DEFAULT_CREDENTIALS_PATH,
    random: () => number = Math.random,
    now: () => number = Date.now,
    migrations: { steps: Record<number, CredentialMigration>; target: number } = {
      steps: CREDENTIAL_MIGRATIONS,
      target: CREDENTIALS_VERSION,
    },
  ) {
    this.path = path
    this.random = random
    this.now = now
    this.migrations = migrations
    this.load()
  }

  /** 读文件；任何读不了的都按未配对待 —— fail closed。 */
  private load(): void {
    try {
      const raw = readFileSync(this.path, 'utf8')
      const parsed = JSON.parse(raw) as Record<string, unknown>
      // 版本先过一遍迁移链：认不出的版本与迁不动的那一步，都按未配对待。
      // 不直接按当前形状硬读 —— 那会读出一份字段不全的凭据，而它看起来是好的。
      const migrated = migrateCredentials(parsed, this.migrations.steps, this.migrations.target)
      this.file = migrated === undefined ? emptyCredentials() : migrated as unknown as StoredCredentials
    } catch {
      // 缺失或损坏：无论哪种都是未配对的保险库 —— 下一次 `pairingCode()`
      // 会签发新码。
      this.file = emptyCredentials()
    }
    this.stamp = this.fingerprint()
  }

  /**
   * 文件的指纹；不存在或 stat 不了时是 `undefined`。
   *
   * 三样一起看：**删除后重建**（inode 变）、**内容长度变**、**改动时刻变**。单看 mtime
   * 挡不住「同一毫秒内换掉文件」，单看 size 挡不住「等长替换」—— 而这是撤销路径，
   * 宁可多算一个字段。
   */
  private fingerprint(): string | undefined {
    try {
      const stats = statSync(this.path)
      return `${stats.mtimeMs}:${stats.size}:${stats.ino}`
    } catch {
      return undefined
    }
  }

  /**
   * 文件在盘上变了就重读 —— 每个闸门进来先问一次。
   *
   * **重读时必须一并清掉 access 表**：那是 15 分钟的票，而删文件的意思是「这层关系
   * 结束了」。只换关系不清票，撤销就还要等票自己过期 —— 那正是这条要修的东西。
   */
  private reloadIfChanged(): void {
    if (this.fingerprint() === this.stamp) return
    log.info('credentials file changed on disk — reloading (access tickets dropped)')
    this.load()
    this.access.clear()
  }

  private persist(): void {
    try {
      mkdirSync(dirname(this.path), { recursive: true })
      writeFileSync(this.path, `${JSON.stringify(this.file, null, 2)}\n`, 'utf8')
    } catch (error) {
      log.error('could not persist credentials', { error: String(error) })
    }
    // 自己写的那一次不该在下一个请求上被当成「别人改的」。
    this.stamp = this.fingerprint()
  }

  /**
   * 要显示在屏幕上的配对码：没有、或旧的已死时签发一枚新的 ——
   * 已经无法被回答的码不得继续展示。
   */
  pairingCode(): string {
    this.reloadIfChanged()
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

  /**
   * 用 device token 换一枚 access token。被拒即关系不存在。
   *
   * **每次成功都轮换设备凭证**：回包里带新的那枚，旧的进宽限。这样「同一层关系被两台
   * 设备用」就有了暴露的方式 —— 它们会互相把对方挤出宽限，而每一次「旧凭证被用了」
   * 都留一条 warn。不轮换的话，两个使用者的一切请求都长得一模一样，日志里看不出来。
   */
  refresh(deviceToken: unknown): {
    ok: true
    accessToken: string
    expiresAt: number
    /** 轮换后的设备凭证 —— 客户端必须存下它，否则下一次就要靠宽限那条回头路。 */
    deviceToken: string
  } | { ok: false } {
    this.reloadIfChanged()
    const now = this.now()
    const outcome = issueAccess(this.file, deviceToken, now, this.random)
    if (outcome.status === 'denied') return { ok: false }

    if (outcome.viaPrevious) {
      // 关系可能被共用：正常客户端每次换票都用最新那枚，走到这里说明有一方落后了 ——
      // 落后是「崩溃在写盘之前」，也可能是「另一台设备拿着旧凭证」。
      log.warn('refresh accepted on the previous device token — the relationship may be shared')
    }

    const rotated = rotateDeviceToken(this.file, now, this.random)
    this.file = rotated.file
    this.persist()
    this.access.set(outcome.tokenHash, { expiresAt: outcome.expiresAt })
    return {
      ok: true,
      accessToken: outcome.token,
      expiresAt: outcome.expiresAt,
      deviceToken: rotated.deviceToken,
    }
  }

  /** HTTP/WS 闸门：该 `Authorization` 头是否指向一枚活跃的 access token？ */
  authenticate(authorizationHeader: string | undefined): boolean {
    this.reloadIfChanged()
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
