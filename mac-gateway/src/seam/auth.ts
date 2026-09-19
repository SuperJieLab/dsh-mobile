/**
 * The auth seam: three tickets, all decisions as pure functions.
 *
 * Model (docs/plans/M4-identity-credentials.md §4.2) — each ticket answers one
 * question, so leaking any one of them is not losing all three:
 *
 *   pairing code   one-shot · 10 min · dead after 5 wrong tries — establishes
 *                  the relationship; only ever answered with a device token
 *   device token   the relationship itself · long-lived · revocable — stored as
 *                  a SHA-256 hash; only ever used to obtain access tokens
 *   access token   a time slice · 15 min · held in memory on both ends — the
 *                  only ticket that may ride a business request
 *
 * Like `rpc.ts`, nothing here touches sockets, files, or the runtime: `random`
 * and `now` are injected, so every rule below is assertable without a network.
 * Hashing uses `node:crypto` — a Node builtin is the one dependency this
 * out-of-tree module may take, and a stored hash (not the raw token) is what
 * makes the credentials file readable without being usable.
 */

import { createHash } from 'node:crypto'

/** How long one access token lives. */
export const ACCESS_TTL_MS = 15 * 60 * 1000

/** How long a pairing code may sit on the screen before it dies. */
export const PAIRING_TTL_MS = 10 * 60 * 1000

/** Wrong tries a pairing code tolerates before it dies early. */
export const PAIRING_MAX_ATTEMPTS = 5

/** What the credentials file holds. Revocation resets to `{ version: 1 }`. */
export interface StoredCredentials {
  version: 1
  /** SHA-256 hex of the device token. Absent while unpaired. */
  deviceTokenHash?: string
  /** The live pairing code, if one has been issued and not yet consumed. */
  pairing?: {
    code: string
    /** Epoch ms after which the code is dead even unused. */
    expiresAt: number
    /** Wrong tries so far. */
    attempts: number
  }
}

/** The empty file — the state revocation returns to. */
export function emptyCredentials(): StoredCredentials {
  return { version: 1 }
}

/** SHA-256 hex of a text. Deterministic, so injectable randomness is not needed here. */
export function sha256Hex(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

/**
 * A 6-digit pairing code. Six digits rather than more because the threat is a
 * bystander at pairing time, not an online brute force — the attempt cap is
 * what bounds that, and it is persistent.
 */
export function newPairingCode(random: () => number): string {
  const value = Math.floor(random() * 1_000_000)
  return String(value).padStart(6, '0')
}

/** 32 random bytes as hex — the shape of both the device and the access token. */
export function newToken(random: () => number): string {
  let hex = ''
  for (let index = 0; index < 32; index += 1) {
    hex += Math.floor(random() * 256).toString(16).padStart(2, '0')
  }
  return hex
}

/** Used by the adapter for in-memory access hashes; exposed so there is one hashing spelling. */

/**
 * `Authorization: Bearer <token>` → the token; anything else → nothing.
 *
 * The header is the only place identity rides (docs/protocol.md §「身份」):
 * putting it in the envelope would weld it to one transport, which is the one
 * thing the protocol's first constraint forbids.
 */
export function bearerTokenOf(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  const match = /^Bearer\s+(\S+)$/.exec(header.trim())
  return match?.[1]
}

/** Whether `code` could be a pairing code at all. Anything else counts as a wrong try. */
export function isPlausiblePairingCode(code: unknown): code is string {
  return typeof code === 'string' && /^\d{6}$/.test(code)
}

/**
 * One pairing attempt, in and out — the file this call leaves behind is part of
 * the verdict, because both the attempt counter and the consumption are state.
 *
 * The code dies three ways: consumed (a successful pair), expired (10 minutes),
 * exhausted (5 wrong tries — including malformed input, which is exactly what
 * a brute force sends). A dead code is removed from the file: a code that can
 * no longer be answered must not linger on disk.
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
    return countAttempt(file) // a malformed try is still a try
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
      // Consumed: the one-shot property, enforced by removal.
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
 * Issue one access token against a presented device token.
 *
 * Returns the raw token exactly once — the server keeps only the hash, so a
 * leaked credentials file cannot mint access tokens.
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

/** Whether an in-memory access record still counts at `now`. */
export function isLiveAccess(record: { expiresAt: number } | undefined, now: number): boolean {
  return record !== undefined && now < record.expiresAt
}
