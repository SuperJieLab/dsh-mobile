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
