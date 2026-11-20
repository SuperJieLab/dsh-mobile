/**
 * 契约文档与实现的形状对账（判据 10）。
 *
 * 契约是两端唯一的口径。它没跟着改的症状是「读文档的人写出一套两端都不认的帧」，
 * 而这种错在代码里看不出来 —— 代码只看自己那一侧。
 *
 * 扫的三件事：
 * - 旧信封的痕迹（`"v": 2`、`"op":`）—— 有就是没改完；
 * - 每个已登记的端点都有一条 `POST /api/<名>` —— 缺了就是文档漏了它；
 * - 失败一定带 `details` 的说明 —— S3 要的同形，文档里得看得到。
 *
 * `dev/` 不进 git：干净 clone 上没有它。所以文件不在时跳过（并在跳过时明说），
 * 否则判据在 CI 上只会抛 ENOENT。
 *
 * Run: node --test tests/protocol/contract-shape.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { UNARY_ENDPOINT_NAMES } from '../../src/wire/unary.ts'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../..')
const CONTRACT = join(ROOT, 'dev/contract/protocol.md')

const read = (): string | undefined => (existsSync(CONTRACT) ? readFileSync(CONTRACT, 'utf8') : undefined)

test('契约里没有旧信封的痕迹', () => {
  const text = read()
  if (text === undefined) {
    // 明确写下跳过，而不是静默通过 —— 后者会让「这一条在 CI 上跑过」变成假话。
    console.log('dev/contract/protocol.md 不存在（干净 clone），跳过')
    return
  }
  assert.equal(text.includes('"v": 2'), false, '版本字段已退役，契约里不该还有它')
  assert.equal(text.includes('"op":'), false, '一元不再用 op 寻址，契约里不该还有它')
})

test('每个端点都在契约里有一条 POST 行', () => {
  const text = read()
  if (text === undefined) return
  for (const name of UNARY_ENDPOINT_NAMES) {
    assert.ok(
      text.includes(`POST /api/${name}`),
      `契约缺了「${name}」的 POST 行 —— 读文档的人会以为这个端点不存在`,
    )
  }
})

test('失败形状的三格在契约里写明，且与流通道同一个说法', () => {
  const text = read()
  if (text === undefined) return
  assert.ok(text.includes('details'), '`details` 这一格得在契约里出现')
  // 两条通道对同一格的说法必须一致：一处写「三键」、另一处写「可选」，客户端就会各写一套。
  const mentions = text.match(/details/g)?.length ?? 0
  assert.ok(mentions >= 3, `「details」只出现 ${mentions} 次 —— 请求/应答/流通道三处都该提到`)
})
