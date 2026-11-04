/**
 * 凭据文件的版本与迁移。
 *
 * 凭据是**丢了要重新配对**的那一类：手机上要重新输码，而码在 Mac 上。所以它比其余存储
 * 更值得一条迁移链 —— 加字段时老用户不该被踢回配对页。
 *
 * 这里守两件事：认不出的版本按未配对处理（fail closed，不硬读），以及迁移链能真的把
 * 一份老文件带上来。
 *
 * Run: node --test tests/remote/credentials-migration.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  CREDENTIALS_VERSION,
  CredentialVault,
  migrateCredentials,
} from '../../src/remote/credentials.ts'
import { sha256Hex } from '../../src/protocol/auth.ts'

function sandbox(): { path: string; done: () => void } {
  const dir = mkdtempSync(join(tmpdir(), 'vault-migrate-'))
  return { path: join(dir, 'credentials.json'), done: () => rmSync(dir, { recursive: true, force: true }) }
}

// ── 迁移链本身 ───────────────────────────────────────────────────────

test('a file already at the current version passes through untouched', () => {
  const file = { version: CREDENTIALS_VERSION, deviceTokenHash: 'abc' }
  assert.deepEqual(migrateCredentials(file), file)
})

test('a version newer than this build is refused, not read', () => {
  // 按当前形状硬读会读出一份字段不全的凭据 —— 而它看起来是好的，认证行为却诡异。
  assert.equal(migrateCredentials({ version: CREDENTIALS_VERSION + 1, deviceTokenHash: 'abc' }), undefined)
})

test('a missing step stops the chain instead of guessing', () => {
  const file = { version: 1, deviceTokenHash: 'abc' }
  assert.equal(migrateCredentials(file, {}, 2), undefined)
})

test('a step that fails stops the chain', () => {
  const file = { version: 1, deviceTokenHash: 'abc' }
  assert.equal(migrateCredentials(file, { 1: () => undefined }, 2), undefined)
})

test('a complete chain carries the file forward', () => {
  // 机制的核心：加 v2 时补一个函数，老文件就走得上来。
  const file = { version: 1, deviceTokenHash: 'abc' }
  const steps = {
    1: (old: Record<string, unknown>) => ({ ...old, version: 2, addedLater: true }),
  }
  const migrated = migrateCredentials(file, steps, 2)
  assert.equal(migrated?.version, 2)
  assert.equal(migrated?.deviceTokenHash, 'abc', '老字段必须原样带过去')
  assert.equal(migrated?.addedLater, true)
})

test('a file with no version at all is treated as version zero', () => {
  // 建版本号之前写下的文件没有 `version` —— 它不是「坏的」，是老格式。
  assert.equal(migrateCredentials({ deviceTokenHash: 'abc' }, {}, 1), undefined,
    '没有 0 号步骤时迁不动 —— 这是对的，不猜')
  const withStep = migrateCredentials(
    { deviceTokenHash: 'abc' },
    { 0: (old) => ({ ...old, version: 1 }) },
    1,
  )
  assert.equal(withStep?.version, 1)
})

// ── 读文件时怎么用它 ─────────────────────────────────────────────────

test('a vault refuses a file whose version it does not know', () => {
  const { path, done } = sandbox()
  try {
    writeFileSync(path, JSON.stringify({ version: 99, deviceTokenHash: 'abc' }))
    const vault = new CredentialVault(path)

    // fail closed：未配对。签得出新码，说明它确实当成「没有凭据」了。
    assert.equal(typeof vault.pairingCode(), 'string')
    assert.deepEqual(vault.refresh('whatever'), { ok: false })
  } finally {
    done()
  }
})

test('a vault reads a file at the current version', () => {
  const { path, done } = sandbox()
  try {
    // 先用真路径写一份正常的，再确认读得回来 —— 正控：拒绝那条不能是「什么都拒」。
    const written = new CredentialVault(path)
    written.seedDeviceToken('device-1')
    const reopened = new CredentialVault(path)
    const issued = reopened.refresh('device-1')
    assert.equal(issued.ok, true, '当前版本的文件必须读得动')
  } finally {
    done()
  }
})

/// 接线：`load()` 真的把文件交给了迁移链，而不是绕过它自己硬读。
///
/// 这一条必须存在 —— 迁移表在生产里是空的（凭据只有一版），循环体永远跑不到。
/// 不注入一份两步的链，「接没接上」没有任何判据看得见：硬读与走链在 v1 / v99 上
/// 给出同一个答案。
test('the vault actually runs the file through the chain', () => {
  const { path, done } = sandbox()
  try {
    // 一份 v1 的文件；这次构造说「当前是 v2」，所以它必须走链才读得进来。
    writeFileSync(path, JSON.stringify({ version: 1, deviceTokenHash: sha256Hex('device-1') }))

    const vault = new CredentialVault(path, Math.random, Date.now, {
      // 这一步**故意换掉哈希**：只有这样才分得开「走了链」与「绕过链硬读」——
      // 若迁移只是补个 version 字段，两条路在 v1 文件上给出同一个答案，判据就是假绿。
      steps: {
        1: (old) => ({ ...old, version: 2, deviceTokenHash: sha256Hex('migrated-token') }),
      },
      target: 2,
    })

    assert.equal(vault.refresh('device-1').ok, false, '走了链就不该还认老 token')
    assert.equal(vault.refresh('migrated-token').ok, true, '走了链就该认迁移之后的那个')
  } finally {
    done()
  }
})

test('the same file stays unpaired when the needed step is missing', () => {
  // 反证：上一条之所以成立，是因为那一步迁移，不是因为别的原因恰好绿了。
  const { path, done } = sandbox()
  try {
    writeFileSync(path, JSON.stringify({ version: 1, deviceTokenHash: sha256Hex('device-1') }))
    const vault = new CredentialVault(path, Math.random, Date.now, { steps: {}, target: 2 })

    assert.equal(vault.refresh('device-1').ok, false, '缺一步就该当未配对 —— 不猜')
  } finally {
    done()
  }
})
