/**
 * 宿主版本检查。
 *
 * 这里守的是「上游漂了能说一句」—— 而它的失败方式很隐蔽：不检查的话，报错会先以
 * 「某个方法不是函数」的形式出现，人就去翻调用点了。
 *
 * Run: node --test tests/host-version.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'

import { BUILT_AGAINST, checkHostVersion, hostVersionOf } from '../src/host-version.ts'

/** 造一棵假的包树。返回入口路径与清理函数。 */
function tree(files: Record<string, unknown>): { argv1: string; done: () => void } {
  const root = mkdtempSync(join(tmpdir(), 'dsh-host-version-'))
  for (const [relative, content] of Object.entries(files)) {
    const path = join(root, relative)
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, typeof content === 'string' ? content : JSON.stringify(content))
  }
  // 入口文件本身只要路径存在即可 —— `hostVersionOf` 只从它的目录往上走。
  const argv1 = join(root, 'node_modules/@deepseek-ai/dsh/dist/bin.js')
  mkdirSync(dirname(argv1), { recursive: true })
  writeFileSync(argv1, '')
  return { argv1, root: root, done: () => rmSync(root, { recursive: true, force: true }) } as never
}

// ── 比对 ─────────────────────────────────────────────────────────────

test('the three states are distinguishable', () => {
  // 读不到是第三种，不能并进「不匹配」—— 它们的补救不同：一个要查入口，一个要升级。
  assert.deepEqual(checkHostVersion(undefined), { kind: 'unknown' })
  assert.deepEqual(checkHostVersion(BUILT_AGAINST), { kind: 'match', version: BUILT_AGAINST })
  assert.deepEqual(checkHostVersion('0.2.2-alpha.9'), {
    kind: 'differs',
    host: '0.2.2-alpha.9',
    builtAgainst: BUILT_AGAINST,
  })
})

test('an alpha-to-alpha move counts as a difference', () => {
  // 严格相等：alpha 之间也可能不兼容，宁可多报一句。
  // 显式传 `builtAgainst` 而不是用常量 —— 判据不该随常量改值而失效。
  assert.equal(checkHostVersion('0.2.2-alpha.2', '0.2.2-alpha.3').kind, 'differs')
  assert.equal(checkHostVersion('0.2.2-alpha.4', '0.2.2-alpha.3').kind, 'differs')
})

// ── 从进程入口读 ─────────────────────────────────────────────────────

test('reads the version from the host manifest', () => {
  const { argv1, done } = tree({
    'node_modules/@deepseek-ai/dsh/package.json': { name: '@deepseek-ai/dsh', version: '0.2.2-alpha.3' },
  })
  try {
    assert.equal(hostVersionOf(argv1), '0.2.2-alpha.3')
  } finally {
    done()
  }
})

test('an unrelated package on the way up is skipped', () => {
  // 沿途会经过 `node_modules` 下别人的 package.json —— 拿第一个就当宿主会读到
  // 完全无关的版本，而那比读不到更坏：它会「匹配」一个假的期望值。
  const root = mkdtempSync(join(tmpdir(), 'dsh-host-skip-'))
  try {
    mkdirSync(join(root, 'node_modules/other/dist'), { recursive: true })
    writeFileSync(join(root, 'node_modules/other/package.json'),
      JSON.stringify({ name: 'other', version: '9.9.9' }))
    writeFileSync(join(root, 'node_modules/other/dist/bin.js'), '')
    writeFileSync(join(root, 'package.json'),
      JSON.stringify({ name: '@deepseek-ai/dsh', version: '0.2.2-alpha.3' }))

    assert.equal(hostVersionOf(join(root, 'node_modules/other/dist/bin.js')), '0.2.2-alpha.3')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('reads through the .bin symlink npx starts the host with', () => {
  // 真机上读不到就是这个原因：npx 把 `node_modules/.bin/dsh` 软链到
  // `@deepseek-ai/dsh/lib/bin.js` 再执行，而 `process.argv[1]` 保留的是软链那一侧。
  // 从 `.bin` 向上走六层永远到不了宿主的 package.json —— 它在 `.bin` 的兄弟目录里，
  // 不在祖先链上。所以「读不到」不是宿主没装，是入口不是我以为的那个路径。
  const root = mkdtempSync(join(tmpdir(), 'dsh-host-bin-'))
  try {
    const real = join(root, 'node_modules/@deepseek-ai/dsh/lib/bin.js')
    mkdirSync(dirname(real), { recursive: true })
    writeFileSync(real, '')
    writeFileSync(join(root, 'node_modules/@deepseek-ai/dsh/package.json'),
      JSON.stringify({ name: '@deepseek-ai/dsh', version: '0.2.2-alpha.3' }))
    const link = join(root, 'node_modules/.bin/dsh')
    mkdirSync(dirname(link), { recursive: true })
    symlinkSync('../@deepseek-ai/dsh/lib/bin.js', link)

    assert.equal(hostVersionOf(link), '0.2.2-alpha.3')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('a missing manifest is unknown, not an error', () => {
  // 读不到版本不该让网关起不来：它可能被测试装配加载，或入口形状变了。
  assert.equal(hostVersionOf('/nonexistent/path/bin.js'), undefined)
  assert.equal(hostVersionOf(undefined), undefined)
  assert.equal(hostVersionOf(''), undefined)
})

test('a manifest without a version is skipped', () => {
  const { argv1, done } = tree({
    'node_modules/@deepseek-ai/dsh/package.json': { name: '@deepseek-ai/dsh' },
  })
  try {
    assert.equal(hostVersionOf(argv1), undefined)
  } finally {
    done()
  }
})

test('a malformed manifest does not throw', () => {
  const { argv1, done } = tree({
    'node_modules/@deepseek-ai/dsh/package.json': 'not json at all',
  })
  try {
    assert.equal(hostVersionOf(argv1), undefined)
  } finally {
    done()
  }
})
