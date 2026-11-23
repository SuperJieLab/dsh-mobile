/**
 * 审计的判据：一次写 op 一条记录。
 *
 * 「哪些端点是写」现在只有一处定义 —— 端点表的 `write` 标记。守它的判据在
 * `tests/remote/http-auth.test.ts`（每个写端点各记一条、读端点一条不记），
 * 不在这里：这里只有 `AuditLog` 自己与 `auditEntryOf` 的映射。
 *
 * Run: node --test tests/audit.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  AuditLog,
  auditEntryOf,
  fileNameOf,
  formatAuditEntry,
  parseAuditEntry,
} from '../src/audit.ts'
import { createRpcListener } from '../src/remote/http.ts'
import type { CredentialVault } from '../src/remote/credentials.ts'
import { IdentityRegistry } from '../src/remote/identity-registry.ts'
import { call } from './helpers/http.ts'

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'dsh-audit-'))
}

// ── 记的是结果，不是意图 ─────────────────────────────────────────────

test('the result comes from the answer, the target from the request', () => {
  const accepted = auditEntryOf('session-prompt', { sessionId: 's-1' }, { ok: true, value: {} })
  assert.equal(accepted.result, 'ok')
  assert.equal(accepted.target, 's-1')

  const refused = auditEntryOf(
    'session-prompt',
    { sessionId: 's-1' },
    { ok: false, error: { code: 'unknown-session', message: 'no stored session', details: {} } },
  )
  assert.equal(refused.result, 'refused')
  assert.equal(refused.code, 'unknown-session')

  // 同一个请求，成功与被拒的目标相同 —— 差别只在结果。这正是「记结果」的意思：
  // 只看目标看不出那次到底改没改，必须看 result。
  assert.equal(refused.target, accepted.target)
})

test('a request without a target records a dash, not a blank', () => {
  // 空值会让「这次没带目标」与「解析坏了」看起来一样，而它们要查的地方不同。
  const entry = auditEntryOf('workspace-delete', {}, { ok: true, value: {} })
  assert.equal(entry.target, '-')
})

test('each write op maps to its own target field', () => {
  const cases: [string, Record<string, unknown>, string][] = [
    ['session-prompt', { sessionId: 's-1' }, 's-1'],
    ['approval-answer', { eventId: 'e-1' }, 'e-1'],
    ['command-execute', { agentId: 's-2' }, 's-2'],
    // 三条跟着宿主的 `request` 容器走：线上多一层，目标在那层里面。
    ['model-select', { request: { sessionId: 's-4' } }, 's-4'],
    ['workspace-create', { name: 'proj' }, 'proj'],
    ['workspace-delete', { request: { workspaceId: 'w-1' } }, 'w-1'],
    ['session-create', { request: { workspaceId: 'w-2' } }, 'w-2'],
  ]
  for (const [op, message, expected] of cases) {
    assert.equal(auditEntryOf(op, message, { ok: true, value: {} }).target, expected, `${op} 的目标取错了`)
  }
})

// ── 一行的形状 ───────────────────────────────────────────────────────

test('an entry round-trips through format and parse', () => {
  const entry = {
    at: '2026-11-04T10:00:00.000+08:00',
    op: 'command-execute',
    target: 's-1',
    result: 'ok' as const,
    request: 'req-abc123',
  }
  assert.deepEqual(parseAuditEntry(formatAuditEntry(entry)), entry)
})

test('a refusal keeps its code', () => {
  const entry = {
    at: '2026-11-04T10:00:00.000+08:00',
    op: 'workspace-delete',
    target: 'w-1',
    result: 'refused' as const,
    code: 'unknown-workspace',
  }
  assert.deepEqual(parseAuditEntry(formatAuditEntry(entry)), entry)
})

test('a line that is not an audit record parses to nothing', () => {
  // 半条记录读成一条比读不出来更坏 —— 猜出来的目标会指向错的地方。
  assert.equal(parseAuditEntry('2026-11-04T10:00:00.000+08:00 [dsh][info][ws] something'), undefined)
  assert.equal(parseAuditEntry(''), undefined)
  assert.equal(parseAuditEntry('2026-11-04T10:00:00.000+08:00 [audit] op=x'), undefined)
})

// ── 落盘与读取 ───────────────────────────────────────────────────────

test('entries land in the month they happened', () => {
  const dir = tempDir()
  try {
    const log = new AuditLog(dir)
    log.append({ op: 'session-prompt', target: 's-1', result: 'ok' }, new Date('2026-11-15T12:00:00Z'))
    log.append({ op: 'session-prompt', target: 's-2', result: 'ok' }, new Date('2026-12-15T12:00:00Z'))

    assert.deepEqual(readdirSync(dir).sort(), ['audit-2026-11.log', 'audit-2026-12.log'])
    assert.equal(fileNameOf('2026-11-15T20:00:00.000+08:00'), 'audit-2026-11.log')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('recent() walks backwards across months', () => {
  const dir = tempDir()
  try {
    const log = new AuditLog(dir)
    log.append({ op: 'a', target: 'first', result: 'ok' }, new Date('2026-11-15T12:00:00Z'))
    log.append({ op: 'b', target: 'second', result: 'ok' }, new Date('2026-11-16T12:00:00Z'))
    log.append({ op: 'c', target: 'third', result: 'ok' }, new Date('2026-12-15T12:00:00Z'))

    assert.deepEqual(log.recent(10).map((entry) => entry.target), ['third', 'second', 'first'])
    // 跨月取最近两条：先读 12 月，够了就不翻 11 月。
    assert.deepEqual(log.recent(2).map((entry) => entry.target), ['third', 'second'])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('recent() on a directory that does not exist is empty, not an error', () => {
  // 审计目录是「第一次写操作时才建」的。查询早于第一次写入时不该抛。
  assert.deepEqual(new AuditLog(join(tmpdir(), 'dsh-audit-missing-xyz')).recent(5), [])
})

test('recent(0) is empty', () => {
  const dir = tempDir()
  try {
    const log = new AuditLog(dir)
    log.append({ op: 'a', target: 'x', result: 'ok' })
    assert.deepEqual(log.recent(0), [])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a write that cannot land is swallowed, not thrown', () => {
  const dir = tempDir()
  try {
    // 用一个**文件**占住目录路径：`mkdir` 会 ENOTDIR。记不下来不该让一次写操作失败 ——
    // 磁盘满时删工作空间失败，是比少一条审计更坏的交换。
    const blocker = join(dir, 'blocked')
    writeFileSync(blocker, '')
    const log = new AuditLog(blocker)
    assert.doesNotThrow(() => log.append({ op: 'a', target: 'x', result: 'ok' }))
    assert.deepEqual(log.recent(5), [])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

// ── 接线：真的请求真的留一条 ─────────────────────────────────────────

/**
 * 传输层真的调了 `append` 吗。
 *
 * 上面几条只证明 `AuditLog` 自己能用；少了这一条，`http.ts` 里少那三行也能让全部绿 ——
 * 而那意味着审计从来没记过任何东西。与 `LogFileTests` 里「`Log` 真的接到文件上了」同一个理由。
 */
test('a real request through the listener leaves a record', { timeout: 10_000 }, async () => {
  const dir = tempDir()
  const audit = new AuditLog(dir)
  const unused = async (): Promise<never> => { throw new Error('not used by this test') }
  const server = createRpcListener({
    sessionPort: {
      list: async () => [],
      page: async () => ({ records: [], hasMore: false, cursor: -1 }),
    },
    vault: { authenticate: () => ({ id: 'test-identity', canAnswer: true }) } as unknown as CredentialVault,
    registry: new IdentityRegistry(),
    writePort: { createSession: unused, promptSession: unused, answerApproval: unused, answerQuestion: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: {
      create: unused,
      delete: async () => {},
    },
    permissionPort: undefined,
    auditLog: audit,
  })

  server.listen(0)
  try {
    await once(server, 'listening')
    const address = server.address() as AddressInfo
    const answer = await call(address.port, 'workspace/delete', { request: { workspaceId: 'w-1' } }, 'test-token')
    assert.equal(answer.status, 200)

    const entries = audit.recent(5)
    assert.equal(entries.length, 1, '一次写 op 必须恰好一条记录')
    assert.equal(entries[0].op, 'workspace-delete')
    assert.equal(entries[0].target, 'w-1')
    assert.equal(entries[0].result, 'ok')
  } finally {
    server.closeAllConnections()
    server.close()
    rmSync(dir, { recursive: true, force: true })
  }
})
