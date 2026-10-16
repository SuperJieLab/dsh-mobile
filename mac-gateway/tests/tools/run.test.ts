/**
 * 场景运行器的判据（R8 期2 Task 4：H4）。
 *
 * H4 —— 同参数连跑两次 → 产物结构一致、条件字段一致（样本量可不同）；
 * 样本不足时**非零退出**：「失败可见」不是一句口号，是退出码。
 *
 * 两条都经真实的子进程 `node tools/bench/run.ts` 验证 —— 产物与退出码都是
 * 那个进程的真实产出，不在测试进程里模拟。
 *
 * Run: node --test tests/tools/run.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const RUN_TS = fileURLToPath(new URL('../../tools/bench/run.ts', import.meta.url))

interface SpawnResult {
  code: number
  stdout: string
  stderr: string
}

function spawnRun(args: string[]): Promise<SpawnResult> {
  return new Promise(resolve => {
    execFile(process.execPath, [RUN_TS, ...args], { timeout: 60_000 }, (error, stdout, stderr) => {
      // 非零退出码走 error 分支；退出码本身才是判据。
      const code = error && typeof (error as { code?: unknown }).code === 'number'
        ? (error as unknown as { code: number }).code
        : error === null ? 0 : 1
      resolve({ code, stdout, stderr })
    })
  })
}

/** 解析产物（单行 JSONL）。 */
function parseArtifact(path: string): {
  runId: string
  condition: Record<string, unknown>
  records: Record<string, unknown>[]
  verdict: { valid: boolean; reasons: string[] }
} {
  const lines = readFileSync(path, 'utf8').trim().split('\n')
  assert.equal(lines.length, 1, 'one run writes one artifact line')
  return JSON.parse(lines[0])
}

test('H4: 同参数连跑两次 → 退出 0，产物结构与条件字段一致', { timeout: 120_000 }, async () => {
  const outDir = mkdtempSync(join(tmpdir(), 'bench-run-'))
  try {
    const args = ['--rate', '300', '--seconds', '3', '--out', outDir]
    const first = await spawnRun(args)
    assert.equal(first.code, 0, `first run exits 0 (stderr: ${first.stderr.slice(-400)})`)
    const second = await spawnRun(args)
    assert.equal(second.code, 0, `second run exits 0 (stderr: ${second.stderr.slice(-400)})`)

    const firstArtifact = parseArtifact(join(outDir, 'run-1.jsonl'))
    const secondArtifact = parseArtifact(join(outDir, 'run-2.jsonl'))

    // 结构一致：顶层键、condition 键、verdict 形状逐一同。
    assert.deepEqual(Object.keys(secondArtifact).sort(), Object.keys(firstArtifact).sort())
    assert.deepEqual(Object.keys(secondArtifact.condition).sort(), Object.keys(firstArtifact.condition).sort())
    assert.deepEqual(Object.keys(secondArtifact.verdict).sort(), Object.keys(firstArtifact.verdict).sort())

    // 条件字段一致：同一命令 → 同一负载条件（client 标签也一致，决定 4）。
    assert.deepEqual(secondArtifact.condition, firstArtifact.condition)
    assert.equal(firstArtifact.condition.client, 'script')
    assert.equal(firstArtifact.condition.eventRate, 300)
    assert.equal(firstArtifact.condition.seconds, 3)

    // 记录的两端都在场：gw 与 dev 都有，且 verdict 有效（决定 6 的三条）。
    const segs = new Set(firstArtifact.records.map(record => record.seg))
    assert.ok(segs.has('gw'), 'gateway-side records are in the artifact')
    assert.ok(segs.has('dev'), 'client-side records are in the artifact')
    assert.equal(firstArtifact.verdict.valid, true)
    assert.deepEqual(firstArtifact.verdict.reasons, [])
  } finally {
    rmSync(outDir, { recursive: true, force: true })
  }
})

test('H4: 样本不足 → 非零退出，verdict 无效且写明原因', { timeout: 120_000 }, async () => {
  const outDir = mkdtempSync(join(tmpdir(), 'bench-run-'))
  try {
    // 5/s 跑 2 秒 ≈ 10 条 < 20：无效点必须当场喊出来。
    const result = await spawnRun(['--rate', '5', '--seconds', '2', '--out', outDir])
    assert.notEqual(result.code, 0, 'an insufficient run must not exit 0')
    const artifact = parseArtifact(join(outDir, 'run-1.jsonl'))
    assert.equal(artifact.verdict.valid, false)
    assert.ok(artifact.verdict.reasons.length > 0, 'the reason rides the artifact, not just the exit code')
    assert.match(artifact.verdict.reasons.join('; '), /event samples/)
  } finally {
    rmSync(outDir, { recursive: true, force: true })
  }
})
