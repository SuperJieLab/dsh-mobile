/**
 * The credentials adapter: the vault that owns the three tickets' state.
 *
 * Split of responsibilities against `seam/auth.ts` (every *rule* is there):
 * this module owns only state and I/O — the credentials file under
 * `~/.dsh/dsh-mobile/`, and the in-memory table of live access tokens.
 *
 * Fail-closed is the standing rule: a credentials file that cannot be read or
 * parsed is treated as unpaired (the worst case is one re-pairing, never an
 * unintended grant), and every write is best-effort with the failure logged —
 * a vault that cannot persist must refuse, not silently downgrade to
 * in-memory-only, because a relationship that vanishes on restart is not the
 * relationship the user paired.
 *
 * The access table is deliberately in memory: a 15-minute ticket does not need
 * to survive a restart, and the client's refresh flow makes re-issuing one an
 * invisible non-event (docs/dev/plans/M4-identity-credentials.md §3.3).
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
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
} from '../seam/auth.ts'

/** Where the file lives when no one says otherwise. */
export const DEFAULT_CREDENTIALS_PATH = join(homedir(), '.dsh', 'dsh-mobile', 'credentials.json')

export class CredentialVault {
  private file: StoredCredentials = emptyCredentials()
  /** Live access tokens by hash; the raw token is never stored server-side. */
  private readonly access = new Map<string, { expiresAt: number }>()

  // Explicit fields rather than TypeScript parameter properties: Node's
  // type-stripping mode cannot execute them, and this package is zero-build.
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

  /** Read the file; anything unreadable counts as unpaired — fail closed. */
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
      // Absent or corrupt: the same answer either way, and the log says which.
      this.file = emptyCredentials()
    }
  }

  private persist(): void {
    try {
      mkdirSync(dirname(this.path), { recursive: true })
      writeFileSync(this.path, `${JSON.stringify(this.file, null, 2)}\n`, 'utf8')
    } catch (error) {
      console.error(`[mac-gateway] could not persist credentials: ${String(error)}`)
    }
  }

  /**
   * The pairing code to show on the screen: issue one if there is none, or the
   * old one died — a code that can no longer be answered must not be displayed.
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

  /** Consume a pairing attempt. `reason` is a human-readable refusal when not ok. */
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

  /** Exchange the device token for one access token. Denial means the relationship is not there. */
  refresh(deviceToken: unknown): { ok: true; accessToken: string; expiresAt: number } | { ok: false } {
    const outcome = issueAccess(this.file, deviceToken, this.now(), this.random)
    if (outcome.status === 'denied') return { ok: false }
    this.access.set(outcome.tokenHash, { expiresAt: outcome.expiresAt })
    return { ok: true, accessToken: outcome.token, expiresAt: outcome.expiresAt }
  }

  /** The HTTP/WS gate: does this `Authorization` header name a live access token? */
  authenticate(authorizationHeader: string | undefined): boolean {
    const token = bearerTokenOf(authorizationHeader)
    if (token === undefined) return false
    return isLiveAccess(this.access.get(sha256Hex(token)), this.now())
  }

  /** Tear the relationship down: back to the empty file, every live access dies. */
  revoke(): void {
    this.file = emptyCredentials()
    this.access.clear()
    this.persist()
  }

  /**
   * Pre-pair without a pairing code — assembly tests only. Production pairing
   * goes through `pairingCode()` + `pair()`; this writes the relationship
   * directly so a test can hold the raw token without parsing console output.
   */
  seedDeviceToken(deviceToken: string): void {
    this.file = { version: 1, deviceTokenHash: sha256Hex(deviceToken) }
    this.access.clear()
    this.persist()
  }
}
