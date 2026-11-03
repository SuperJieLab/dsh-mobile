/**
 * 凭据库的「撤销」语义 —— 删掉文件必须立刻生效。
 *
 * 撤销只有一条路：删掉 `credentials.json`。原来读盘只发生在构造时，于是删了文件之后
 * 进程仍认着内存里那份关系、手里那枚 access 票也还能用满 15 分钟 —— 丢手机时「去 Mac 上
 * 删文件」并不解决问题，只是让问题在 15 分钟后才解决。
 *
 * 这里的三条判据都围绕同一个问题：**盘上的事实变了，内存里什么时候知道**。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, rmSync, unlinkSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { CredentialVault } from '../../src/remote/credentials.ts'

/** 每条用例一个临时目录：真凭据文件在 ~/.dsh 下，测试不许碰。 */
function sandbox(): { dir: string; path: string; done: () => void } {
  const dir = mkdtempSync(join(tmpdir(), 'vault-revoke-'))
  return { dir, path: join(dir, 'credentials.json'), done: () => rmSync(dir, { recursive: true, force: true }) }
}

test('deleting the credentials file revokes the live ticket immediately', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')
    const issued = vault.refresh('device-1')
    assert.equal(issued.ok, true)
    const ticket = issued.ok ? issued.accessToken : ''
    // 正控：票本来是有效的。少了这一条，「删文件后失效」在票本来就无效时也绿。
    assert.equal(vault.authenticate(`Bearer ${ticket}`), true, '前置：刚换到的票应当有效')

    unlinkSync(path)

    assert.equal(vault.authenticate(`Bearer ${ticket}`), false,
      '删掉凭据文件必须让手里的票立刻失效 —— 这是唯一的撤销手段')
    assert.deepEqual(vault.refresh('device-1'), { ok: false },
      '关系已经不存在，换票也要被拒')
  } finally {
    done()
  }
})

test('replacing the file with another relationship refuses the old device token', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')
    assert.equal(vault.refresh('device-1').ok, true)

    // 另一个保险库在同一路径上建立另一层关系 —— 等价于有人手工换掉了文件。
    // 把 mtime 推到未来：两次写可能落在同一毫秒里，而这里要测的是「内容变了」，
    // 不是「同一毫秒内换文件」那个边界。
    new CredentialVault(path).seedDeviceToken('device-2')
    const later = new Date(Date.now() + 1_000)
    utimesSync(path, later, later)

    assert.deepEqual(vault.refresh('device-1'), { ok: false },
      '文件里的关系换了，旧 device token 就不该再换得到票')
    assert.equal(vault.refresh('device-2').ok, true, '新的那一层关系照常可用')
  } finally {
    done()
  }
})

test('writing the file ourselves does not drop live tickets', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')
    const issued = vault.refresh('device-1')
    const ticket = issued.ok ? issued.accessToken : ''

    // `pairingCode()` 会在没有有效码时签发并落盘 —— 这是**自己写**的那一次。
    vault.pairingCode()

    assert.equal(vault.authenticate(`Bearer ${ticket}`), true,
      '自己刚写的文件不该被当成「别人改的」而清掉票 —— 那会让每次配对码刷新踢掉在线客户端')
  } finally {
    done()
  }
})
