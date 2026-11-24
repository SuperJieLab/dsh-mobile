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
import { mkdtempSync, readFileSync, rmSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { CredentialVault } from '../../src/remote/credentials.ts'
import { issueAccess, sha256Hex, type StoredCredentials } from '../../src/protocol/auth.ts'

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
    assert.ok(vault.authenticate(`Bearer ${ticket}`) !== undefined, '前置：刚换到的票应当有效')

    unlinkSync(path)

    assert.equal(vault.authenticate(`Bearer ${ticket}`), undefined,
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

    assert.ok(vault.authenticate(`Bearer ${ticket}`) !== undefined,
      '自己刚写的文件不该被当成「别人改的」而清掉票 —— 那会让每次配对码刷新踢掉在线客户端')
  } finally {
    done()
  }
})

// MARK: - 设备凭证轮换

test('every refresh hands back a new device token', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')

    const first = vault.refresh('device-1')
    assert.equal(first.ok, true)
    assert.ok(first.ok && first.deviceToken !== 'device-1', '续期必须轮换：回包里是新的那一枚')

    const second = first.ok ? vault.refresh(first.deviceToken) : undefined
    assert.equal(second?.ok, true)
    assert.ok(second?.ok && second.deviceToken !== first.deviceToken, '每次都要换，不是只换第一次')
  } finally {
    done()
  }
})

test('the replaced token is accepted exactly once inside the grace window', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')
    const first = vault.refresh('device-1')
    assert.equal(first.ok, true)

    // 被替换掉的那一枚进宽限：客户端崩在「收到新凭证、还没写盘」之间时靠它走回来。
    assert.equal(vault.refresh('device-1').ok, true, '宽限里那条回头路必须通')

    // 但它只值一次：第二次轮换已经把它挤出去了 —— 这正是「第二个使用者会暴露」的形状。
    assert.deepEqual(vault.refresh('device-1'), { ok: false },
      '同一枚旧凭证不能被无限次换票')
  } finally {
    done()
  }
})

test('the grace window is a boundary, not a mood', () => {
  const file: StoredCredentials = {
    version: 2,
    deviceTokenHash: sha256Hex('current'),
    previous: { hash: sha256Hex('previous'), until: 5_000 },
  }
  const at = (now: number, token: string) => issueAccess(file, token, now, Math.random)

  assert.equal(at(4_999, 'previous').status, 'ok', '到期前一毫秒还算数')
  assert.equal(at(5_000, 'previous').status, 'denied', '到点即作废')
  assert.equal(at(9_999, 'current').status, 'ok', '当前那枚不受宽限影响')
  assert.equal(at(9_999, 'stranger').status, 'denied')
})

test('rotating does not invalidate tickets already in hand', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')
    const first = vault.refresh('device-1')
    const ticket = first.ok ? first.accessToken : ''
    assert.ok(vault.authenticate(`Bearer ${ticket}`) !== undefined, '前置：票是有效的')

    if (first.ok) vault.refresh(first.deviceToken)

    assert.ok(vault.authenticate(`Bearer ${ticket}`) !== undefined,
      '换的是设备凭证，不是手里那张没到期的票 —— 作废它等于每 15 分钟踢一次在线客户端')
  } finally {
    done()
  }
})

// MARK: - 身份

test('换两次票、重开一次保险库，解析出的身份仍是同一个', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')

    const first = vault.refresh('device-1')
    assert.equal(first.ok, true)
    const firstIdentity = first.ok ? vault.authenticate(`Bearer ${first.accessToken}`) : undefined
    assert.ok(firstIdentity !== undefined, '前置：第一枚票能解析出身份')
    assert.equal(firstIdentity.canAnswer, true, '配对出来的设备是 owner')

    // 第二次用**轮换后**的 token 换票：身份跟着关系走，不跟着 token 走。
    const second = first.ok ? vault.refresh(first.deviceToken) : undefined
    const secondIdentity = second?.ok ? vault.authenticate(`Bearer ${second.accessToken}`) : undefined
    assert.equal(secondIdentity?.id, firstIdentity.id, '换票不得换身份 —— 否则 409 永远不成立')

    // 重开一个保险库读同一个文件：身份不能只活在内存里。用**最新**那枚 device token ——
    // 两次轮换已经把最初那枚挤出了宽限。
    const currentToken = second?.ok ? second.deviceToken : ''
    const reopened = new CredentialVault(path)
    const third = reopened.refresh(currentToken)
    const thirdIdentity = third.ok ? reopened.authenticate(`Bearer ${third.accessToken}`) : undefined
    assert.equal(thirdIdentity?.id, firstIdentity.id, '重启之后身份还是它')
    assert.equal(thirdIdentity?.canAnswer, true)
  } finally {
    done()
  }
})

test('a live ticket whose file names no identity is refused (fail closed)', () => {
  const { path, done } = sandbox()
  try {
    const vault = new CredentialVault(path)
    vault.seedDeviceToken('device-1')
    const issued = vault.refresh('device-1')
    assert.ok(issued.ok, '前置：配对出来的关系能换票')
    const original = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>
    const identityId = original['identityId']
    assert.equal(typeof identityId, 'string', '前置：配对写出了身份')

    // 手工抹掉身份：票还活着，但文件答不出「谁」。
    const stripped = { ...original }
    delete stripped['identityId']
    writeFileSync(path, JSON.stringify(stripped))
    const later = new Date(Date.now() + 1_000)
    utimesSync(path, later, later)

    // **换一张新票再验**。这一步是判据的关键：改文件会触发 `reloadIfChanged`，
    // 它连带清掉 access 表（撤销语义），于是刚才那张票已经失活 —— 直接拿它断言
    // 「被拒」时，红的可能是「票失效」而不是「说不出身份」，这条判据就白写了。
    const fresh = vault.refresh('device-1')
    assert.ok(fresh.ok, '前置：文件变了，但关系还在 —— 新票该拿到')
    const ticket = fresh.ok ? fresh.accessToken : ''
    assert.equal(vault.authenticate(`Bearer ${ticket}`), undefined,
      '说不出是谁的票不该被当成一个身份 —— fail closed')

    // 正控：把身份写回去，同一张票就认得出人。少了这一条，上面那句在「票根本无效」时也绿。
    writeFileSync(path, JSON.stringify({ ...stripped, identityId }))
    const later2 = new Date(Date.now() + 2_000)
    utimesSync(path, later2, later2)
    const again = vault.refresh('device-1')
    const restored = again.ok ? vault.authenticate(`Bearer ${again.accessToken}`) : undefined
    assert.equal(restored?.id, identityId, '身份回来之后，同一段关系又认得出人了')
  } finally {
    done()
  }
})
