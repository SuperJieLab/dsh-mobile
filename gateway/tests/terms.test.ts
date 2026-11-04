/**
 * 术语回潮检查（R13 期2）—— 扫网关源码、测试、工具与四份活文档，命中 `terms.txt` 里的
 * 反模式即失败。
 *
 * 词表在仓库根（`terms.txt`），iOS 侧读同一份 ⇒ 结构上不可能漂移。表里还有一组
 * 「自查样本」（`expect-hit` / `expect-pass`）：加载后先跑一遍，**规则被改坏时这里先红**，
 * 不必等仓库真的回潮。
 *
 * 只报不改：`承载` 按句意分两种写法（组网 / 传输），没有唯一解，自动替换正是期1 那 60 处
 * 误伤的来源。
 *
 * 豁免：`terms-ok:<理由>` 行内豁免，或 `terms-ok:start` / `terms-ok:end` 块豁免。
 * 块**必须配对** —— 未闭合会让余下全文静默失明，所以扫描结束时会单独报错并指出 `:start`
 * 所在行。豁免了什么会被打印出来：豁免应当可见，否则「散文里写一句 terms-ok:」就能
 * 静默关掉一行而无人知道。
 *
 * `dev/` 不进 git：干净 clone 上没有私有工作区。**`dev/` 整个不存在**时跳过文档并告警；
 * 它在、但四份之中缺一份，则是工作区残缺，报错。
 *
 * Run: node --test tests/terms.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** 仓库根：本文件在 `gateway/tests/`，向上两级。 */
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..')

/** 网关侧要扫的活文档（`dev/features/*` 是过程留痕，不在范围内）。 */
const DOCS = ['dev/PROJECT.md', 'dev/RULES.md', 'dev/ISSUES.md', 'dev/contract/protocol.md']

type Rule = { word: string; re: RegExp; advice: string; reason: string }
type Sample = { expect: 'hit' | 'pass'; text: string; line: number }
type Table = { rules: Rule[]; samples: Sample[] }

/** 正则统一带 `u` —— 否则 `\p{...}` 这类会被静默降级成字面量，两端语义分叉。 */
const REGEXP_FLAGS = 'u'

function loadTable(): Table {
  const text = readFileSync(join(ROOT, 'terms.txt'), 'utf8')
  const rules: Rule[] = []
  const samples: Sample[] = []
  text.split('\n').forEach((raw, index) => {
    const line = raw.trim()
    if (!line || line.startsWith('#')) return
    const where = `terms.txt:${index + 1}`
    if (line.startsWith('expect-hit;') || line.startsWith('expect-pass;')) {
      const [kind, ...rest] = line.split(';')
      const body = rest.join(';').trim()
      if (!body) throw new Error(`${where} 的自查样本是空的`)
      samples.push({ expect: kind === 'expect-hit' ? 'hit' : 'pass', text: body, line: index + 1 })
      return
    }
    const parts = line.split(';').map((p) => p.trim())
    if (parts.length < 3) throw new Error(`${where} 格式不对（应为 词;正则;建议[;理由]）: ${line}`)
    const [word, pattern, advice, reason = ''] = parts
    if (!pattern) throw new Error(`${where} 有空正则（${word}）—— 它会命中每一行: ${line}`)
    try {
      rules.push({ word, re: new RegExp(pattern, REGEXP_FLAGS), advice, reason })
    } catch (error) {
      throw new Error(`${where} 的正则写错了（${word}）: ${pattern} —— ${String(error)}`)
    }
  })
  return { rules, samples }
}

function collectFiles(dir: string, ext: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) collectFiles(full, ext, out)
    else if (full.endsWith(ext)) out.push(full)
  }
  return out
}

/**
 * `terms-ok:start` / `terms-ok:end` / `terms-ok:<理由>`；没带冒号或理由为空都不算标记。
 * 冒号后允许空白 —— 中文注释习惯写成「terms-ok: 理由」，不放宽会静默失效。
 */
function markerOf(line: string): 'start' | 'end' | 'line' | null {
  const match = line.match(/terms-ok:\s*(\S+)/)
  if (!match) return null
  if (match[1] === 'start') return 'start'
  if (match[1] === 'end') return 'end'
  return match[1].length > 0 ? 'line' : null
}

type ScanResult = { hits: string[]; exempted: string[] }

function scan(files: string[], rules: Rule[]): ScanResult {
  const hits: string[] = []
  const exempted: string[] = []
  for (const file of files) {
    const rel = relative(ROOT, file)
    let blockOpenAt = 0
    readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
      const marker = markerOf(line)
      if (marker === 'end') {
        blockOpenAt = 0
        return
      }
      if (marker === 'start') {
        blockOpenAt = index + 1
        return
      }
      if (marker === 'line') {
        exempted.push(`${rel}:${index + 1}`)
        return
      }
      if (blockOpenAt > 0) return
      for (const rule of rules) {
        if (rule.re.test(line)) {
          const why = rule.reason ? `（${rule.reason}）` : ''
          hits.push(`${rel}:${index + 1}  「${rule.word}」→ ${rule.advice}${why}`)
        }
      }
    })
    if (blockOpenAt > 0) {
      hits.push(`${rel}:${blockOpenAt}  terms-ok:start 没有配对的 :end —— 从这里到文件末尾被跳过`)
    }
  }
  return { hits, exempted }
}

test('术语回潮检查：网关源码、测试、工具与活文档里不出现已退役的写法', () => {
  const { rules, samples } = loadTable()
  assert.ok(rules.length > 0, 'terms.txt 里一条规则都没解析出来')
  assert.ok(samples.length > 0, 'terms.txt 里一条自查样本都没有 —— 规则被改坏时会静默全绿')

  // 先让规则自己过一遍样本：`expect-hit` 必须命中，`expect-pass` 必须不命中。
  const wrong: string[] = []
  for (const sample of samples) {
    const matched = rules.filter((rule) => rule.re.test(sample.text))
    const ok = sample.expect === 'hit' ? matched.length > 0 : matched.length === 0
    if (!ok) {
      const detail = matched.length ? `被「${matched.map((r) => r.word).join('、')}」命中` : '一条规则都没命中'
      wrong.push(`terms.txt:${sample.line}  expect-${sample.expect} 被违反 —— ${detail}：${sample.text}`)
    }
  }
  assert.equal(wrong.length, 0, `自查样本与规则不一致（改规则时把样本也一起看）：\n${wrong.join('\n')}`)

  // `dev/` 整个不在 = 干净 clone，跳过；在、但缺某份 = 工作区残缺，报错。
  const devExists = existsSync(join(ROOT, 'dev'))
  const missing = DOCS.filter((d) => !existsSync(join(ROOT, d)))
  if (devExists) {
    assert.equal(missing.length, 0, `dev/ 在，但缺这几份活文档（工作区残缺）：${missing.join('、')}`)
  } else {
    console.warn(`⚠️ dev/ 不在工作区（干净 clone），跳过 ${DOCS.length} 份活文档`)
  }
  const docs = devExists ? DOCS.map((d) => join(ROOT, d)) : []

  const files = [
    ...collectFiles(join(ROOT, 'gateway/src'), '.ts'),
    ...collectFiles(join(ROOT, 'gateway/tests'), '.ts').filter((f) => !f.endsWith('terms.test.ts')),
    ...collectFiles(join(ROOT, 'gateway/tools'), '.ts'),
    ...docs,
  ]
  // 扫到 0 个文件时 hits 也是空 —— 那会静默变绿，所以先断言扫到了东西。
  assert.ok(files.length > 20, `只扫到 ${files.length} 个文件 —— 路径推算错了？`)

  const { hits, exempted } = scan(files, rules)
  if (exempted.length) console.warn(`ℹ️ 行内豁免 ${exempted.length} 处：${exempted.join('、')}`)
  assert.equal(hits.length, 0, `发现已退役的写法（改成建议列里的说法）：\n${hits.join('\n')}`)
})
