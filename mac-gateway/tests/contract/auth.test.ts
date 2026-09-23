/**
 * Auth contract tests (M4): every rule the three tickets promise, on pure functions
 * with injected randomness and clock — no filesystem, no socket.
 * Run: node --test tests/contract/auth.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  ACCESS_TTL_MS,
  PAIRING_MAX_ATTEMPTS,
  PAIRING_TTL_MS,
  attemptPairing,
  bearerTokenOf,
  emptyCredentials,
  isLiveAccess,
  isPlausiblePairingCode,
  issueAccess,
  newPairingCode,
  newToken,
  sha256Hex,
  type StoredCredentials,
} from '../../src/contract/auth.ts'

/** Deterministic randomness: always returns the values, then 0 forever. */
function seededRandom(values: number[]): () => number {
  let index = 0
  return () => (index < values.length ? values[index++]! : 0)
}

/** A file with a live pairing code, issued at `t0`. */
function fileWithPairing(t0: number, randomValues: number[] = [0.424242]): { file: StoredCredentials; code: string } {
  const code = newPairingCode(seededRandom(randomValues))
  return { file: { version: 1, pairing: { code, expiresAt: t0 + PAIRING_TTL_MS, attempts: 0 } }, code }
}

// MARK: - tokens & codes

test('a pairing code is six digits and derived from the injected randomness', () => {
  assert.equal(newPairingCode(seededRandom([0])), '000000')
  assert.equal(newPairingCode(seededRandom([0.999999])), '999999')
  assert.equal(newPairingCode(seededRandom([0.5])), '500000')
})

test('a token is 64 hex characters — 256 bits', () => {
  const token = newToken(seededRandom([0.1, 0.2, 0.3]))
  assert.match(token, /^[0-9a-f]{64}$/)
})

test('identical texts hash identically and the hash never contains the input', () => {
  assert.equal(sha256Hex('abc'), sha256Hex('abc'))
  assert.notEqual(sha256Hex('abc'), sha256Hex('abd'))
})

test('bearer parsing accepts exactly the Bearer scheme and nothing else', () => {
  assert.equal(bearerTokenOf('Bearer abc123'), 'abc123')
  assert.equal(bearerTokenOf('bearer abc123'), undefined) // scheme is case-sensitive: the standard says so
  assert.equal(bearerTokenOf('Basic abc123'), undefined)
  assert.equal(bearerTokenOf('Bearer'), undefined)
  assert.equal(bearerTokenOf(undefined), undefined)
  assert.equal(bearerTokenOf('  Bearer   spaced  '), 'spaced')
})

test('a pairing code must look like one before it is counted as a wrong try', () => {
  assert.equal(isPlausiblePairingCode('123456'), true)
  assert.equal(isPlausiblePairingCode('12345'), false)
  assert.equal(isPlausiblePairingCode('abcdef'), false)
  assert.equal(isPlausiblePairingCode(123456), false)
})

// MARK: - pairing

test('a correct code pairs once and is consumed: the same code never pairs twice', () => {
  const t0 = 1_000_000
  const { file, code } = fileWithPairing(t0)

  const first = attemptPairing(file, code, t0 + 1, seededRandom([0.7]))
  assert.equal(first.status, 'paired')
  if (first.status !== 'paired') return
  assert.equal(first.file.deviceTokenHash, sha256Hex(first.deviceToken))
  assert.equal(first.file.pairing, undefined) // consumed — the one-shot property

  const second = attemptPairing(first.file, code, t0 + 2, seededRandom([0.7]))
  assert.equal(second.status, 'invalid-code') // no live code left to answer
})

test('a wrong code is counted, and the count is the whole point: 5 tries kill the code', () => {
  const t0 = 1_000_000
  const { file, code } = fileWithPairing(t0)

  let current = file
  for (let attempt = 0; attempt < PAIRING_MAX_ATTEMPTS - 1; attempt += 1) {
    const outcome = attemptPairing(current, '000000', t0 + 1, seededRandom([0.7]))
    assert.equal(outcome.status, 'invalid-code')
    current = outcome.file
    assert.equal(current.pairing?.attempts, attempt + 1)
  }

  const last = attemptPairing(current, '000000', t0 + 1, seededRandom([0.7]))
  assert.equal(last.status, 'code-exhausted')
  assert.equal(last.file.pairing, undefined) // dead code removed from the file

  // The real code is dead too — exhaustion kills it, not just the wrong tries.
  const after = attemptPairing(last.file, code, t0 + 1, seededRandom([0.7]))
  assert.equal(after.status, 'invalid-code')
})

test('a malformed guess counts as a wrong try — that is exactly what a brute force sends', () => {
  const t0 = 1_000_000
  const { file } = fileWithPairing(t0)

  const outcome = attemptPairing(file, 'abcdef', t0 + 1, seededRandom([0.7]))
  assert.equal(outcome.status, 'invalid-code')
  assert.equal(outcome.file.pairing?.attempts, 1)
})

test('an expired code is refused and removed, even when the answer would have been right', () => {
  const t0 = 1_000_000
  const { file, code } = fileWithPairing(t0)

  const outcome = attemptPairing(file, code, t0 + PAIRING_TTL_MS, seededRandom([0.7]))
  assert.equal(outcome.status, 'code-expired')
  assert.equal(outcome.file.pairing, undefined)
})

test('pairing against an unpaired file is refused without inventing state', () => {
  const outcome = attemptPairing(emptyCredentials(), '123456', 0, seededRandom([0.7]))
  assert.equal(outcome.status, 'invalid-code')
  assert.equal(outcome.file.pairing, undefined)
})

// MARK: - access

test('only the hash-matching device token can mint an access token', () => {
  const t0 = 2_000_000
  const { file: pairedFile } = (() => {
    const pairing = fileWithPairing(t0)
    const outcome = attemptPairing(pairing.file, pairing.code, t0, seededRandom([0.7]))
    if (outcome.status !== 'paired') throw new Error('setup failed')
    return { file: outcome.file }
  })()

  const good = issueAccess(pairedFile, newToken(seededRandom([0.7])), t0, seededRandom([0.9]))
  assert.equal(good.status, 'ok') // the token just issued above is the one the hash names

  const wrong = issueAccess(pairedFile, 'not-the-token', t0, seededRandom([0.9]))
  assert.equal(wrong.status, 'denied')

  const unpaired = issueAccess(emptyCredentials(), 'whatever', t0, seededRandom([0.9]))
  assert.equal(unpaired.status, 'denied')
})

test('an access token lives exactly ACCESS_TTL_MS and is judged by the server clock', () => {
  const t0 = 2_000_000
  const device = newToken(seededRandom([0.7]))
  const file: StoredCredentials = { version: 1, deviceTokenHash: sha256Hex(device) }

  const issued = issueAccess(file, device, t0, seededRandom([0.9]))
  if (issued.status !== 'ok') return assert.fail('issuance should succeed')
  assert.equal(issued.expiresAt, t0 + ACCESS_TTL_MS)

  const record = { expiresAt: issued.expiresAt }
  assert.equal(isLiveAccess(record, issued.expiresAt - 1), true)
  assert.equal(isLiveAccess(record, issued.expiresAt), false) // half-open: expiry excludes itself
  assert.equal(isLiveAccess(undefined, t0), false)
})
