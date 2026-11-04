/**
 * 审计的判据：一次写 op 一条记录，且「哪些 op 是写」只有一处定义。
 *
 * 最要紧的是第一条 —— 它守的是「新加一个写 op 却忘了进 `WRITE_OPS`」。那种漏法不会让
 * 任何行为判据变红：请求照常成功，只是事后查不到。审计最不能有的失败方式就是静默地少记。
 *
 * Run: node --test tests/audit.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { readFileSync } from 'node:fs'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  AuditLog,
  WRITE_OPS,
  auditEntryOf,
  fileNameOf,
  formatAuditEntry,
  parseAuditEntry,
} from '../src/audit.ts'
import { DEFAULT_LIMITS, failure, success } from '../src/protocol/rpc.ts'
import { createRpcListener } from '../src/remote/http.ts'
import type { CredentialVault } from '../src/remote/credentials.ts'
import { PROTOCOL_VERSION } from '../src/wire/rpc.ts'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src')

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'dsh-audit-'))
}

// ── 清单与协议层一一对应 ──────────────────────────────────────────────

/**
 * `rpc.ts` 里标了「写 op」的分支。
 *
 * 扫的是**注释标记**而不是语义 —— 静态分不出「哪个分支会改东西」。这是判据的固有局限，
 * 所以下面带活性锚：注释格式一变，扫到的数量会掉，判据自己会红，而不是静默放行。
 *
 * 两个相邻 `case` 共用一个注释（`approval-answer` / `session-prompt`）时，靠「中间没有
 * 别的代码行」把它们归成一组。
 */
function writeOpsMarkedIn(source: string): string[] {
  const found: string[] = []
  let pending: string[] = []

  for (const line of source.split('\n')) {
    const trimmed = line.trim()

    const opened = /^case '([^']+)':\s*\{?$/.exec(trimmed)
    if (opened !== null) {
      pending.push(opened[1])
      continue
    }

    if (pending.length > 0 && /^\/\/\s*写 op/.test(trimmed)) {
      found.push(...pending)
      pending = []
      continue
    }

    // 任何别的代码行都结束 pending：那个 case 分支不是写 op。
    if (trimmed !== '' && !trimmed.startsWith('//')) pending = []
  }
  return found
}

test('every write op marked in rpc.ts is declared in WRITE_OPS', () => {
  const source = readFileSync(join(SRC, 'protocol', 'rpc.ts'), 'utf8')
  const declared = writeOpsMarkedIn(source)

  // 活性锚：扫到的太少说明注释格式变了 —— 那时「两边一致」只是因为两边都空。
  assert.ok(
    declared.length >= 5,
    `只扫到 ${declared.length} 个写 op 标记 —— 先怀疑扫法，别信这条判据`,
  )

  assert.deepEqual(
    [...declared].sort(),
    [...WRITE_OPS].sort(),
    'rpc.ts 里标了「写 op」的分支与 audit.ts 的 WRITE_OPS 必须一一对应 —— '
      + '少一个，那个 op 就静默地没有审计记录',
  )
})

// ── 记的是结果，不是意图 ─────────────────────────────────────────────

test('the result comes from the answer, the target from the request', () => {
  const accepted = auditEntryOf('session-prompt', { sessionId: 's-1' }, success({}))
  assert.equal(accepted.result, 'ok')
  assert.equal(accepted.target, 's-1')

  const refused = auditEntryOf(
    'session-prompt',
    { sessionId: 's-1' },
    failure('unknown-session', 'no stored session'),
  )
  assert.equal(refused.result, 'refused')
  assert.equal(refused.code, 'unknown-session')

  // 同一个请求，成功与被拒的目标相同 —— 差别只在结果。这正是「记结果」的意思：
  // 只看目标看不出那次到底改没改，必须看 result。
  assert.equal(refused.target, accepted.target)
})

test('a request without a target records a dash, not a blank', () => {
  // 空值会让「这次没带目标」与「解析坏了」看起来一样，而它们要查的地方不同。
  const entry = auditEntryOf('workspace-delete', {}, success({}))
  assert.equal(entry.target, '-')
})

test('each write op maps to its own target field', () => {
  const cases: [string, Record<string, unknown>, string][] = [
    ['session-prompt', { sessionId: 's-1' }, 's-1'],
    ['approval-answer', { eventId: 'e-1' }, 'e-1'],
    ['command-execute', { sessionId: 's-2' }, 's-2'],
    ['permission-select', { sessionId: 's-3' }, 's-3'],
    ['model-select', { sessionId: 's-4' }, 's-4'],
    ['workspace-create', { name: 'proj' }, 'proj'],
    ['workspace-delete', { workspaceId: 'w-1' }, 'w-1'],
    ['session-create', { workspaceId: 'w-2' }, 'w-2'],
  ]
  for (const [op, message, expected] of cases) {
    assert.equal(auditEntryOf(op, message, success({})).target, expected, `${op} 的目标取错了`)
  }
})

// ── 一行的形状 ───────────────────────────────────────────────────────

test('an entry round-trips through format and parse', () => {
  const entry = {
    at: '2026-11-04T10:00:00.000+08:00',
    op: 'permission-select',
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
      read: async () => undefined,
      readAll: async () => undefined,
    },
    limits: DEFAULT_LIMITS,
    vault: { authenticate: () => true } as unknown as CredentialVault,
    writePort: { createSession: unused, promptSession: unused, answerApproval: unused },
    modelPort: undefined,
    commandPort: undefined,
    workspacePort: {
      snapshot: () => ({ workspaces: [] }) as never,
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
    const response = await fetch(`http://127.0.0.1:${address.port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer test-token' },
      body: JSON.stringify({ v: PROTOCOL_VERSION, op: 'workspace-delete', workspaceId: 'w-1' }),
    })
    assert.equal(response.status, 200)

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
