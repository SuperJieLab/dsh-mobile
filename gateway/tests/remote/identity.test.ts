/**
 * 登记表：一个身份只许一条 socket（判据 2 的机制半边、判据 3、判据 6）。
 *
 * 这一层是纯记账，所以判据全部离网：造一条假 socket 就能问清「名额怎么还、
 * 归属什么时候丢」。真端口上那一条（判据 2 的 409）在 `tests/index.test.ts`。
 *
 * 判据 6 只能在这里做：凭证文件只存**一段关系**，所以真实端口上造不出第二个身份 ——
 * 那条判据在端到端那一层是写着玩不了的。
 *
 * Run: node --test tests/remote/identity.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import type { Duplex } from 'node:stream'

import { IdentityRegistry } from '../../src/remote/identity-registry.ts'
import { setLogSink } from '../../src/log.ts'

/** 一条假 socket：登记表只拿它当键，不碰它的任何方法。 */
function socket(): Duplex {
  return {} as Duplex
}

const alice = { id: 'i-alice', canAnswer: true }
const bob = { id: 'i-bob', canAnswer: true }

test('判据 3：同一身份第二次占名额被拒，释放之后又可以占', () => {
  const registry = new IdentityRegistry()
  const first = socket()

  assert.equal(registry.claim(alice, first), true, '第一个名额该给')
  assert.equal(registry.claim(alice, socket()), false, '同一身份的第二条 socket 必须被拒')
  assert.equal(registry.size, 1, '被拒的那条不占名额')

  registry.release(first)
  assert.equal(registry.claim(alice, socket()), true, '关掉之后名额回来了 —— 否则一次断连就再连不上')
})

test('判据 3：释放一条 socket 连带清掉它名下流的归属', () => {
  // 只还名额不清归属，会让一条已经不存在的流继续「有主人」：它上面挂着的 clientId
  // 此后每次应答都判成越权，而日志里没有一行说明那条流早就不在了。
  const registry = new IdentityRegistry()
  const owner = socket()
  registry.claim(alice, owner)
  registry.openStream('c-1', owner)
  assert.equal(registry.ownerOf('c-1'), alice.id, '前置：流登记上了')

  registry.release(owner)

  assert.equal(registry.ownerOf('c-1'), undefined, 'socket 没了，它的流也就不该再有主人')
  assert.equal(registry.identityOf(owner), undefined)
})

test('判据 6：两个不同身份各占一条，互不冲突', () => {
  // 「按身份判」与「按 socket 数判」在这一条上分得开：按 socket 数判的实现会把
  // 第二条拒掉，而它其实是另一个人的。
  const registry = new IdentityRegistry()
  assert.equal(registry.claim(alice, socket()), true)
  assert.equal(registry.claim(bob, socket()), true)
  assert.equal(registry.size, 2)
})

test('一条流的主人取自它那条 socket 的身份', () => {
  const registry = new IdentityRegistry()
  const a = socket()
  const b = socket()
  registry.claim(alice, a)
  registry.claim(bob, b)
  registry.openStream('c-a', a)
  registry.openStream('c-b', b)

  assert.equal(registry.ownerOf('c-a'), alice.id)
  assert.equal(registry.ownerOf('c-b'), bob.id)
  assert.equal(registry.ownerOf('c-unknown'), undefined, '没下发过的 clientId 没有主人')
})

test('关掉一条流只删它自己那一格', () => {
  const registry = new IdentityRegistry()
  const owner = socket()
  registry.claim(alice, owner)
  registry.openStream('c-1', owner)
  registry.openStream('c-2', owner)

  registry.closeStream('c-1')

  assert.equal(registry.ownerOf('c-1'), undefined)
  assert.equal(registry.ownerOf('c-2'), alice.id, '同一身份的另一条流不该跟着消失')
})

test('未归属的 socket 上开流不会被登记（并留下一条 warn）', () => {
  // 装配漏了 claim 时，这里静默登记会让应答把一条流判给一个不存在的身份。
  const registry = new IdentityRegistry()
  registry.openStream('c-1', socket())
  assert.equal(registry.ownerOf('c-1'), undefined)
})

test('同一 clientId 被两条流复用时留一条 warn，后写覆盖（换代不该走到这里）', () => {
  // 这条 warn 的反面正是判据 5 的反证：换代（同一 socket 重入）必须**不响**，
  // 而真出现两条流抢同一个 id 时必须响 —— 两个方向都要有判据，否则「把 warn 删掉」
  // 与「把正常路径也灌进来」都看不出来。
  const registry = new IdentityRegistry()
  const lines: string[] = []
  const previous = setLogSink((_level, _module, line) => { lines.push(line) })
  try {
    const first = socket()
    const second = socket()
    registry.claim(alice, first)
    registry.claim(bob, second)
    registry.openStream('c-1', first)
    registry.openStream('c-1', second)

    assert.equal(registry.ownerOf('c-1'), bob.id, '后写覆盖：最后一条流是主人')
    assert.ok(lines.some(line => line.includes('opened twice')),
      `真出现两条流抢同一个 id 时要留痕；实际日志：${lines.join(' / ')}`)
  } finally {
    setLogSink(previous)
  }
})
