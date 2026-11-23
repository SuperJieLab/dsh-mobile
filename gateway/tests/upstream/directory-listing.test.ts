/**
 * 目录读面的单元判据：网关自己读文件系统那一层。
 *
 * 打的是真目录（临时建的），因为这一层的全部意义就是「与机器上的实际目录一致」——
 * 用替身目录表会把「排序」「hidden」「crumbs 拼错」这类错法全遮掉。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { directoryListingOver } from '../../src/upstream/directory-listing.ts'

const uncancelled = new AbortController().signal

/** 建一棵临时树，交给回调，收尾删掉。 */
async function withTree(run: (root: string) => Promise<void>): Promise<void> {
  const root = mkdtempSync(join(tmpdir(), 'dsh-listing-unit-'))
  mkdirSync(join(root, 'beta'))
  mkdirSync(join(root, 'alpha'))
  mkdirSync(join(root, '.hidden'))
  mkdirSync(join(root, 'alpha', 'inner'))
  writeFileSync(join(root, 'note.txt'), 'x')
  try {
    await run(root)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

test('one level: directories only, name order, hidden marked, absolute paths', async () => {
  await withTree(async (root) => {
    const listing = await directoryListingOver().list(root, uncancelled) as {
      path: string
      home: string
      entries: { name: string; path: string; hidden: boolean }[]
      truncated: boolean
    }
    assert.equal(listing.path, root)
    assert.equal(listing.home, (await import('node:os')).homedir())
    assert.deepEqual(listing.entries.map(entry => entry.name), ['.hidden', 'alpha', 'beta'],
      '文件不进来；点开头的进来但标 hidden；顺序与区域设置无关')
    assert.deepEqual(listing.entries.map(entry => entry.hidden), [true, false, false])
    assert.deepEqual(listing.entries.map(entry => entry.path),
      [join(root, '.hidden'), join(root, 'alpha'), join(root, 'beta')])
    assert.equal(listing.truncated, false)
  })
})

test('crumbs run from the file-system root down to this level', async () => {
  await withTree(async (root) => {
    const listing = await directoryListingOver().list(join(root, 'alpha', 'inner'), uncancelled) as {
      crumbs: { name: string; path: string }[]
      entries: unknown[]
    }
    assert.equal(listing.crumbs[0]?.path, '/', '第一格永远是根')
    assert.equal(listing.crumbs.at(-1)?.path, join(root, 'alpha', 'inner'), '最后一格是这一层')
    assert.deepEqual(listing.entries, [], '没有子目录就给空 —— 不是 null')
  })
})

test('a relative path is refused, not resolved against the process cwd', async () => {
  // 相对路径会落到守护进程的工作目录上 —— 那是与用户意图无关的一层，且看起来完全正常。
  await assert.rejects(() => directoryListingOver().list('some/dir', uncancelled),
    /must be absolute/)
})

test('the level is truncated at the limit and says so', async () => {
  await withTree(async (root) => {
    const listing = await directoryListingOver(2).list(root, uncancelled) as {
      entries: { name: string }[]
      truncated: boolean
    }
    assert.deepEqual(listing.entries.map(entry => entry.name), ['.hidden', 'alpha'])
    assert.equal(listing.truncated, true, '截断了就要说 —— 否则用户以为到底了')
  })
})

test('a symlink to a directory is a directory; a broken one is skipped', async () => {
  await withTree(async (root) => {
    symlinkSync(join(root, 'alpha'), join(root, 'linked'))
    symlinkSync(join(root, 'gone'), join(root, 'broken'))
    const listing = await directoryListingOver().list(root, uncancelled) as {
      entries: { name: string }[]
    }
    assert.deepEqual(listing.entries.map(entry => entry.name), ['.hidden', 'alpha', 'beta', 'linked'],
      '断链跳过、指向目录的收下')
  })
})

test('a missing directory rejects instead of returning an empty level', async () => {
  // 空列表与「这个目录不存在」在屏幕上完全一样，而后者要用户改路径。
  await assert.rejects(() => directoryListingOver().list('/no-such-directory-here', uncancelled),
    /ENOENT/)
})
