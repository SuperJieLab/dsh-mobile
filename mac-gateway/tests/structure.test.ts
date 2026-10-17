/**
 * 结构判据（R15 期1）—— 守的是「目录名能预测内容」这件事，不是某个行为。
 *
 * 为什么这些判据要进测试而不是开工时跑一次 `grep`：它们全是「零命中」型 —— 路径写错、
 * 目录没建、正则打错，读出来都是零命中，判据不会因为自己失效而报错。所以还要有
 * **样本自证**（`importsOf` 的用例）：违规样本必须命中、合规样本不得命中、认不出的
 * 写法（重导出 / 动态 import）必须报错而不是静默跳过。
 *
 * 目录分工（判据来源见 `dev/features/R15-gateway-layering/spec.md` 的场景 1、2）：
 *
 *   wire/      两端共守的形状与编解码 —— 改它，手机端必须同改
 *   ports/     装配边界：端口接口与上游失败的词汇
 *   protocol/  服务端协议判定            （期2 才出现）
 *   remote/    面向手机的传输
 *   upstream/  面向 DSH 宿主的适配
 *
 * Run: node --test tests/structure.test.ts
 */
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '../src')

// ---------------------------------------------------------------------------
// 读源码：去注释 → 取 import 边
// ---------------------------------------------------------------------------

/**
 * 去掉注释，保留字符串字面量。
 *
 * 手写扫描器而不是按 `//` 正则删：源码里有 `'https://…'` 这类字符串，正则会把它们
 * 从 `//` 处截断 —— 于是后面若有 import 就整条消失，判据静默失明。
 */
export function stripComments(source: string): string {
  let out = ''
  let cursor = 0
  for (const span of commentSpans(source)) {
    out += source.slice(cursor, span.start)
    cursor = span.end
  }
  return out + source.slice(cursor)
}

/** 源码里的注释区间（含定界符），按出现顺序。扫描器只认「引号之外」的注释。 */
export function commentSpans(source: string): { start: number; end: number; text: string }[] {
  const spans: { start: number; end: number; text: string }[] = []
  let quote: string | undefined
  let i = 0
  while (i < source.length) {
    const ch = source[i] as string
    const next = source[i + 1]
    if (quote !== undefined) {
      if (ch === '\\') {
        i += 2
        continue
      }
      if (ch === quote) quote = undefined
      i += 1
      continue
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      quote = ch
      i += 1
      continue
    }
    if (ch === '/' && next === '/') {
      const start = i
      while (i < source.length && source[i] !== '\n') i += 1
      spans.push({ start, end: i, text: source.slice(start, i) })
      continue
    }
    if (ch === '/' && next === '*') {
      const start = i
      i += 2
      while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) i += 1
      i += 2
      spans.push({ start, end: Math.min(i, source.length), text: source.slice(start, i) })
      continue
    }
    i += 1
  }
  return spans
}

/** `export … from '…'` —— 它会在 import 图里造出一条边，而我们的扫描器只认 `import`。 */
const RE_EXPORT = /^[ \t]*export\b[^;]*\bfrom\s*(['"])/m
/** 动态 `import(...)` —— 同上，边在运行期才出现。 */
const DYNAMIC_IMPORT = /\bimport\s*\(/

/**
 * 一个文件的 import 边（模块说明符，原样）。
 *
 * **认不出的写法直接抛错**，不静默跳过：跳过等于把一条真实的依赖从图里抹掉，
 * 而判据是「零命中」型，抹掉之后它更绿。要支持新写法，先改这里。
 */
export function importsOf(source: string): string[] {
  const code = stripComments(source)
  if (RE_EXPORT.test(code)) throw new Error('unsupported import form: `export … from` — extend importsOf() first')
  if (DYNAMIC_IMPORT.test(code)) throw new Error('unsupported import form: dynamic `import()` — extend importsOf() first')
  const specifiers: string[] = []
  for (const pattern of [/\bfrom\s*(['"])([^'"]+)\1/g, /\bimport\s*(['"])([^'"]+)\1/g]) {
    for (const match of code.matchAll(pattern)) {
      const specifier = match[2]
      if (specifier !== undefined && !specifiers.includes(specifier)) specifiers.push(specifier)
    }
  }
  return specifiers
}

/** 目录下全部 `.ts` 文件（递归，不跟进符号链接）。 */
export function filesUnder(directory: string): string[] {
  if (!existsSync(directory) || !statSync(directory).isDirectory()) {
    throw new Error(`${relative(SRC, directory)}/ does not exist yet — create the directory this judge guards`)
  }
  const found: string[] = []
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry)
    if (statSync(path).isDirectory()) found.push(...filesUnder(path))
    else if (entry.endsWith('.ts')) found.push(path)
  }
  return found
}

/** Node 内建模块：`node:fs` 与裸写 `fs` 两种写法都算。 */
function isBuiltin(specifier: string): boolean {
  return specifier.startsWith('node:')
}

/**
 * 某目录内、跨出该目录的 import。返回 `{ file, specifier }`。
 *
 * 「跨出」= 解析后的目标文件不在该目录下。同目录的相对引用（`./x.ts`）不算 ——
 * 目录内部的边当然存在，判据管的是**它伸出去了没有**。
 */
export function outgoingImports(directory: string): { file: string; specifier: string }[] {
  const escaped: { file: string; specifier: string }[] = []
  for (const file of filesUnder(directory)) {
    for (const specifier of importsOf(readFileSync(file, 'utf8'))) {
      if (isBuiltin(specifier)) continue
      if (!specifier.startsWith('.')) {
        escaped.push({ file, specifier }) // 裸包名：也不该出现在底座目录里
        continue
      }
      const target = resolve(dirname(file), specifier)
      if (target !== directory && !target.startsWith(directory + sep)) {
        escaped.push({ file, specifier })
      }
    }
  }
  return escaped
}

/** 某目录内的 import 图（`文件 → 同目录内的目标文件`），用于环检测。 */
function importGraph(directory: string): Map<string, string[]> {
  const graph = new Map<string, string[]>()
  for (const file of filesUnder(directory)) {
    const targets: string[] = []
    for (const specifier of importsOf(readFileSync(file, 'utf8'))) {
      if (!specifier.startsWith('.')) continue
      const target = resolve(dirname(file), specifier)
      if (target.startsWith(directory + sep)) targets.push(target)
    }
    graph.set(file, targets)
  }
  return graph
}

/** 图里的一条回边（若存在）。DFS，返回环上的路径便于定位。 */
export function firstCycle(graph: Map<string, string[]>): string[] | undefined {
  const state = new Map<string, 'visiting' | 'done'>()
  const stack: string[] = []
  const walk = (node: string): string[] | undefined => {
    if (state.get(node) === 'done') return undefined
    if (state.get(node) === 'visiting') return [...stack.slice(stack.indexOf(node)), node]
    state.set(node, 'visiting')
    stack.push(node)
    for (const next of graph.get(node) ?? []) {
      const cycle = walk(next)
      if (cycle !== undefined) return cycle
    }
    stack.pop()
    state.set(node, 'done')
    return undefined
  }
  for (const node of graph.keys()) {
    const cycle = walk(node)
    if (cycle !== undefined) return cycle
  }
  return undefined
}

/** 一个小文件的定位串：相对 `src/`，失败信息里好读。 */
function where(file: string): string {
  return relative(SRC, file)
}

function format(escaped: { file: string; specifier: string }[]): string {
  return escaped.map(({ file, specifier }) => `  ${where(file)} → ${specifier}`).join('\n')
}

// ---------------------------------------------------------------------------
// 样本自证：判据自己先得会响
// ---------------------------------------------------------------------------

test('the parser reads import edges, not comments or strings', () => {
  // 这条守的是「判据不会因为自己的解析器失明而变绿」。
  const source = [
    "import { a } from './a.ts'",
    "import type { B } from '../wire/b.ts'",
    "import 'node:fs'",
    "// import { ghost } from '../ghost.ts'",
    "/* import { phantom } from '../phantom.ts' */",
    "const url = 'https://example.com/x'",
    "import { c } from '../c.ts'",
  ].join('\n')
  assert.deepEqual(
    importsOf(source).sort(),
    ['./a.ts', '../wire/b.ts', 'node:fs', '../c.ts'].sort(),
    '注释掉的 import 不得出现；字符串里的 `//` 不得把后面的 import 吃掉',
  )
})

test('the parser refuses forms it cannot follow', () => {
  assert.throws(() => importsOf("export { a } from './a.ts'"), /export … from/, 're-export')
  assert.throws(() => importsOf("export * from './a.ts'"), /export … from/, 'star re-export')
  assert.throws(() => importsOf("const m = await import('./a.ts')"), /dynamic/, 'dynamic import')
})

test('the parser separates same-directory edges from escaping ones', () => {
  const graph = new Map([
    ['/w/a.ts', ['/w/b.ts']],
    ['/w/b.ts', ['/w/a.ts']],
  ])
  assert.deepEqual(firstCycle(graph), ['/w/a.ts', '/w/b.ts', '/w/a.ts'], 'a cycle is found')
  const acyclic = new Map([
    ['/w/a.ts', ['/w/b.ts']],
    ['/w/b.ts', []],
  ])
  assert.equal(firstCycle(acyclic), undefined, 'no cycle, no report')
})

// ---------------------------------------------------------------------------
// V1 / V2：底座两目录的依赖方向
// ---------------------------------------------------------------------------

test('wire/ does not reach outside itself', () => {
  const escaped = outgoingImports(join(SRC, 'wire'))
  assert.deepEqual(escaped, [],
    `wire/ holds the shapes both ends share; it may only import itself and node builtins:\n${format(escaped)}`)
})

test('ports/ only reaches into wire/', () => {
  const escaped = outgoingImports(join(SRC, 'ports')).filter(({ specifier }) => {
    // 同目录的 `./` 已在 outgoingImports 里被排除；这里只剩「伸出去」的，必须指向 wire/
    return !(specifier === '../wire' || specifier.startsWith('../wire/'))
  })
  assert.deepEqual(escaped, [],
    `ports/ is the assembly boundary: it may import wire/ (its signatures name wire types) and nothing else:\n${format(escaped)}`)
})

// ---------------------------------------------------------------------------
// V3：面向宿主的适配层不认识传输层
// ---------------------------------------------------------------------------

test('upstream/ does not import remote/', () => {
  const escaped = outgoingImports(join(SRC, 'upstream'))
    .filter(({ specifier }) => specifier === '../remote' || specifier.startsWith('../remote/'))
  assert.deepEqual(escaped, [],
    `the host adapter must not know the transport — a port it needs belongs in ports/:\n${format(escaped)}`)
})

// ---------------------------------------------------------------------------
// V4：wire/ 内部无环
// ---------------------------------------------------------------------------

test('wire/ has no import cycle', () => {
  const cycle = firstCycle(importGraph(join(SRC, 'wire')))
  assert.equal(cycle, undefined,
    `shape modules must not depend on each other in a loop: ${cycle?.map(where).join(' → ')}`)
})

// ---------------------------------------------------------------------------
// V5：wire/ 只导形状与编解码
// ---------------------------------------------------------------------------

/**
 * `wire/` 允许导出的函数 —— **成对写**：每个编解码器配它服务的那个形状。
 *
 * 凑不出配对的函数，就说明它不是编解码（窗口算术、请求分派都长这样），该去别的目录。
 * 新增导出函数必须先改这张表 —— 改表这个动作会让人停下来回答「它属于哪个形状」。
 */
const WIRE_CODECS: readonly { file: string; name: string; shape: string }[] = [
  { file: 'mux.ts', name: 'parseClientFrame', shape: 'MuxClientFrame' },
  { file: 'mux.ts', name: 'encodeServerFrame', shape: 'MuxServerFrame' },
  { file: 'mux.ts', name: 'followRequestOf', shape: 'FollowRequest' },
  { file: 'model.ts', name: 'modelSelectRequestOf', shape: 'ModelSelectMessage' },
  { file: 'write.ts', name: 'approvalAnswerOf', shape: 'ApprovalAnswerMessage' },
  { file: 'write.ts', name: 'sessionPromptOf', shape: 'SessionPromptMessage' },
]

/** 导出的函数式声明：`export function x` 与 `export const x = (…) =>` 都算。 */
export function exportedFunctionsOf(source: string): string[] {
  const code = stripComments(source)
  const names: string[] = []
  for (const match of code.matchAll(/\bexport\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) {
    if (match[1] !== undefined) names.push(match[1])
  }
  for (const match of code.matchAll(/\bexport\s+const\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s*)?(?:\(|function\b)/g)) {
    if (match[1] !== undefined) names.push(match[1])
  }
  return names
}

test('wire/ exports shapes and codecs, nothing else', () => {
  const actual: string[] = []
  for (const file of filesUnder(join(SRC, 'wire'))) {
    for (const name of exportedFunctionsOf(readFileSync(file, 'utf8'))) actual.push(name)
  }
  const expected = WIRE_CODECS.map(codec => codec.name)
  assert.deepEqual(actual.sort(), [...expected].sort(),
    'a function that cannot be paired with the shape it encodes is not a codec — it belongs in protocol/')
})

// ---------------------------------------------------------------------------
// V6：源码注释不指向开发工作区
// ---------------------------------------------------------------------------

test('no source comment points into the workspace docs', () => {
  const offenders: string[] = []
  for (const file of filesUnder(SRC)) {
    for (const span of commentSpans(readFileSync(file, 'utf8'))) {
      if (/\bdev\//.test(span.text)) offenders.push(`${where(file)}: ${span.text.trim().slice(0, 90)}`)
    }
  }
  assert.deepEqual(offenders, [],
    'workspace docs are not published — a comment that only points at them is a dead link to repo readers')
})
