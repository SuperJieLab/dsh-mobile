/**
 * 结构判据 —— 守的是「目录名能预测内容」这件事，不是某个行为。
 *
 * 为什么这些判据要进测试而不是开工时跑一次 `grep`：它们全是「零命中」型 —— 路径写错、
 * 目录没建、正则打错，读出来都是零命中，判据不会因为自己失效而报错。所以每一条
 * 真正被调用的解析函数都配了**样本自证**：违规样本必须命中、合规样本不得命中、
 * 认不出的写法（重导出 / 动态 import / 认不出的导出形态）必须报错而不是静默跳过。
 *
 * 目录分工（判据来源是需求文档的场景 1、2，那份文档不随仓库发布，所以这里把它说清）：
 *
 *   wire/      两端共守的形状与编解码 —— 改它，手机端必须同改
 *   ports/     装配边界：端口接口与上游失败的词汇
 *   protocol/  服务端协议判定
 *   remote/    面向手机的传输
 *   upstream/  面向 DSH 宿主的适配
 *
 * 已知边界（写在代码里而不是留给下一个人踩）：`importsOf` 不区分模板字符串与
 * 正则字面量里的 `from '…'`，`src/` 目前没有这种形态；真出现时会假红或翻乱引号
 * 状态，到那时扩展 `stripComments`。
 *
 * Run: node --test tests/structure.test.ts
 */
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { isBuiltin as isBuiltinModule } from 'node:module'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import test from 'node:test'

import type { MuxServerFrame, StreamId } from '../src/wire/mux.ts'

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
function stripComments(source: string): string {
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
  let i = 0
  while (i < source.length) {
    const ch = source[i] as string
    const next = source[i + 1]
    // 引号之内没有注释：跳过去。这一句与 `skipString` 是同一套规则，两处各写一份就会漂。
    if (ch === "'" || ch === '"' || ch === '`') {
      i = skipString(source, i)
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

/** 动态 `import(...)` —— 边在运行期才出现，静态扫描读不到，必须报错而不是跳过。 */
const DYNAMIC_IMPORT = /\bimport\s*\(/

/**
 * 一个文件的 import 边（模块说明符，原样）。**含 `export … from` 的重导出边** ——
 * 它同样是一条依赖，看不见它就会让 V1/V2 漏判。
 *
 * **动态 `import()` 直接抛错**，不静默跳过：跳过等于把一条真实的依赖从图里抹掉，
 * 而判据是「零命中」型，抹掉之后它更绿。要支持这种写法，先改这里。
 */
export function importsOf(source: string): string[] {
  const code = stripComments(source)
  if (DYNAMIC_IMPORT.test(code)) throw new Error('unsupported import form: dynamic `import()` — extend importsOf() first')
  const specifiers: string[] = []
  for (const pattern of [
    /\bfrom\s*(['"])([^'"]+)\1/g,
    /\bimport\s*(['"])([^'"]+)\1/g,
  ]) {
    for (const match of code.matchAll(pattern)) {
      const specifier = match[2]
      if (specifier !== undefined && !specifiers.includes(specifier)) specifiers.push(specifier)
    }
  }
  return specifiers
}

/** 目录下的全部源码文件（递归，不跟进符号链接）。三种扩展名都要收：漏一种就等于不扫它。 */
export function filesUnder(directory: string): string[] {
  if (!existsSync(directory) || !statSync(directory).isDirectory()) {
    throw new Error(`${relative(SRC, directory)}/ does not exist yet — create the directory this judge guards`)
  }
  const found: string[] = []
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry)
    if (statSync(path).isDirectory()) found.push(...filesUnder(path))
    else if (SOURCE_EXTENSIONS.some(extension => entry.endsWith(extension))) found.push(path)
  }
  return found
}

/**
 * 算得上「本仓源码」的扩展名。`src/` 今天全用 `.ts`，但 `.mts` / `.cts` 也是合法
 * TypeScript —— 只收 `.ts` 的话，一个 `.mts` 文件对所有判据都是隐形的。
 */
const SOURCE_EXTENSIONS = ['.ts', '.mts', '.cts'] as const

/** `target` 是否落在 `directory` 内（含该目录本身）。 */
function within(target: string, directory: string): boolean {
  return target === directory || target.startsWith(directory + sep)
}

/**
 * 一条相对 import 的**归一化目标文件**。
 *
 * `import './b'` 与 `import './sub'` 都指得到实际文件，但字符串形态
 * 各不相同。不做这一步，环检测会把它们当成「图外节点」静默丢边 —— 而本条判据是
 * 零命中型，丢边只会让它更绿。**认不出就抛错**，与「认不出的写法必须报错」同一原则。
 */
export function resolutionOf(
  file: string,
  specifier: string,
  exists: (path: string) => boolean = existsSync,
): string {
  const base = resolve(dirname(file), specifier)
  // 只有「带扩展名」与「省略扩展名」两种。目录 import（`./sub` → `sub/index.ts`）当前
  // 全仓没有，不做猜测：真出现会在这里报错，那时再补候选 —— 猜错比报错更难查。
  const candidates = [base, ...SOURCE_EXTENSIONS.map(extension => `${base}${extension}`)]
  for (const candidate of candidates) {
    if (SOURCE_EXTENSIONS.some(extension => candidate.endsWith(extension)) && exists(candidate)) return candidate
  }
  throw new Error(
    `${relative(dirname(file), base)}: cannot resolve this import to a source file — the structure judge only understands explicit targets`,
  )
}

/**
 * 一个文件的 import 里，**跨出 `directory`** 的那些（纯函数，样本可直接钉住它）。
 *
 * 「跨出」按**解析后的路径**判，不按字符串前缀：`'../wire/../../protocol/x.ts'`
 * 前缀像 `../wire/`，实际落在 `protocol/`。裸包名一律算跨出 —— 底座目录不该引
 * 任何第三方包。
 */
export function escapedFrom(
  file: string,
  specifiers: readonly string[],
  directory: string,
  exists: (path: string) => boolean = existsSync,
): { specifier: string; target?: string }[] {
  const escaped: { specifier: string; target?: string }[] = []
  for (const specifier of specifiers) {
    // Node 内建：用运行时的判据，不自己维护名单 —— 裸写 `fs` 与 `node:fs` 都算。
    if (isBuiltinModule(specifier)) continue
    if (!specifier.startsWith('.')) {
      escaped.push({ specifier })
      continue
    }
    const target = resolutionOf(file, specifier, exists)
    if (!within(target, directory)) escaped.push({ specifier, target })
  }
  return escaped
}

/** 读一个目录下的全部源文件与它们的 import 边 —— 判据的输入端，只此一处。 */
export function unitsUnder(directory: string): { file: string; specifiers: string[] }[] {
  return filesUnder(directory).map(file => ({ file, specifiers: importsOf(readFileSync(file, 'utf8')) }))
}

/**
 * 一批文件里、跨出 `directory` 的 import（纯函数，样本可直接钉住它）。
 *
 * 拆出来是因为 V1/V2/V3 的入口若只是一个把三件事串起来的壳，把壳打坏（比如目录
 * 参数传错、返回恒空）时，样本测的都是里面那件，判据已经瞎了而样本全绿。
 */
export function escapedAmong(
  units: readonly { file: string; specifiers: readonly string[] }[],
  directory: string,
  exists: (path: string) => boolean = existsSync,
): { file: string; specifier: string; target?: string }[] {
  const escaped: { file: string; specifier: string; target?: string }[] = []
  for (const { file, specifiers } of units) {
    for (const escape of escapedFrom(file, specifiers, directory, exists)) escaped.push({ file, ...escape })
  }
  return escaped
}

/** 某目录内、跨出该目录的 import。 */
export function outgoingImports(directory: string): { file: string; specifier: string; target?: string }[] {
  return escapedAmong(unitsUnder(directory), directory)
}

/**
 * 一批文件构成的 import 图，只保留**目录内**的边（纯函数，样本可直接钉住它）。
 *
 * 归一化在 {@link resolutionOf} 里：`./b`、`./sub` 都指得到真文件，
 * 不归一化就会被当成图外节点、边被静默丢掉，而环检测是零命中型判据。
 */
export function graphAmong(
  units: readonly { file: string; specifiers: readonly string[] }[],
  directory: string,
  exists: (path: string) => boolean = existsSync,
): Map<string, string[]> {
  const graph = new Map<string, string[]>()
  for (const { file, specifiers } of units) {
    const targets: string[] = []
    for (const specifier of specifiers) {
      if (!specifier.startsWith('.')) continue
      const target = resolutionOf(file, specifier, exists)
      if (within(target, directory)) targets.push(target)
    }
    graph.set(file, targets)
  }
  return graph
}

/** 某目录内的 import 图（`文件 → 同目录内的目标文件`），用于环检测。 */
function importGraph(directory: string): Map<string, string[]> {
  return graphAmong(unitsUnder(directory), directory)
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

/** 样本的前提前提：这些真文件必须在。缺了先说清，别让读者对着 `cannot resolve` 猜。 */
function requireFiles(paths: readonly string[]): void {
  for (const path of paths) {
    assert.ok(existsSync(path), `sample premise: ${relative(SRC, path)} must exist for this judge's samples`)
  }
}

// ---------------------------------------------------------------------------
// 样本自证：判据自己先得会响
//
// 每条都钉住一个**真的会被 V1–V6 用到的**函数。理由：这些判据全是零命中型，
// 判据失效与判据通过看起来一样；而「测了解析器 A、判据用的是 B」这种错位，
// 会让样本绿着、判据已经瞎了。
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

test('the scanner keeps its place across a template, its interpolation, and a nested one', () => {
  // 这条守的是扫描器**自己的**失效方式：模板里的嵌套模板若被当成「本层收尾」，
  // 扫描器从那里起在代码与字符串之间翻个面，之后整段文件的注释、import、导出
  // 都判错 —— 而所有零命中型判据都只会因此更绿（假绿，没人会知道）。
  const source = [
    "const paint = `a ${ x === undefined ? 'b' : `no \\`x\\` (${y})` } tail`",
    'const after = 1',
    "// import { ghost } from '../ghost.ts'",
    "import { real } from '../real.ts'",
  ].join('\n')
  assert.deepEqual(importsOf(source), ['../real.ts'],
    'the commented import stays a comment, and the real one after it is still a code edge')
})


test('the parser refuses forms it cannot follow', () => {
  // 动态 import 的边只有运行期才存在，静态扫描读不到 —— 报错，别当成没有依赖。
  assert.throws(() => importsOf("const m = await import('./a.ts')"), /dynamic/, 'dynamic import')
  // 反过来：重导出**是**一条依赖边，必须被认出来（看不见它，V1/V2 就会漏判）。
  assert.deepEqual(
    importsOf("export { a } from './a.ts'\nexport * from '../wire/b.ts'"),
    ['./a.ts', '../wire/b.ts'],
    're-exports are edges too',
  )
})

test('the cycle finder reports a loop, and stays quiet without one', () => {
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
  assert.deepEqual(firstCycle(new Map([['/w/a.ts', ['/w/a.ts']]])), ['/w/a.ts', '/w/a.ts'], 'a self-loop is a cycle')
})

/**
 * 分层判据的样本：同目录不算跨出、Node 内建不算、跨目录算、裸包名算。
 *
 * 判的是「规格」而不是「解析器」：这几类正是 spec 里允许面与禁止面的边界，
 * 任何一条判反了都会让 V1/V2/V3 给出错误的答案（假红会被人关掉，假绿会烂在原地）。
 */
test('the escaping-import judge tells same-directory, wire, and outside apart', () => {
  const wire = join(SRC, 'wire')
  const file = join(wire, 'mux.ts')
  // 前提：这条样本用真文件（`resolutionOf` 会查文件系统）。文件被挪走时，先在这里说清，
  // 而不是让读者对着 `cannot resolve` 猜是判据坏了还是源码变了。
  requireFiles([file, join(wire, 'rpc.ts'), join(SRC, 'protocol', 'rpc.ts')])
  // 同目录：不算跨出
  assert.deepEqual(escapedFrom(file, ['./rpc.ts'], wire), [], 'same-directory import is not escaping')
  // Node 内建：两种写法都不算（裸写 `fs` 也算内建 —— 否则会假红）
  assert.deepEqual(escapedFrom(file, ['node:fs', 'fs'], wire), [], 'node builtins are allowed, bare or prefixed')
  // 跨目录：按解析后的路径判
  assert.deepEqual(
    escapedFrom(file, ['../protocol/rpc.ts'], wire).map(e => e.specifier),
    ['../protocol/rpc.ts'],
    'a sibling directory is escaping',
  )
  assert.deepEqual(
    escapedFrom(file, ['../wire/../protocol/rpc.ts'], wire).map(e => e.specifier),
    ['../wire/../protocol/rpc.ts'],
    'a path that merely *starts* with ../wire/ still escapes — judged by target, not by prefix',
  )
  // 裸包名：底座目录不该引第三方包
  assert.deepEqual(
    escapedFrom(file, ['lodash'], wire).map(e => e.specifier),
    ['lodash'],
    'a bare package name is not allowed in a base directory',
  )
})

/**
 * 这条钉的是 V1/V2/V3 的入口 `escapedAmong`（以及它上面的 `unitsUnder`）。
 *
 * 只测 `escapedFrom` 不够：入口若把目录参数传错、或返回恒空，判据就瞎了，而那条
 * 样本仍然绿 —— 「测了里面那件、判据用的是外面那层」是本文件反复要防的错位。
 */
test('the directory-level judge reports across files and honours the directory it was given', () => {
  const wire = join(SRC, 'wire')
  // 入口本身也要能读到真文件 —— 它若返回空列表，下面所有判据都成了空转。
  const units = unitsUnder(wire)
  assert.ok(units.length > 0, 'the reader must actually find files — an empty list would make every judge vacuous')
  assert.ok(units.some(u => u.specifiers.length > 0), 'and it must actually read their imports')

  // 样本用内存文件视图，不依赖源码树此刻长什么样。
  const files = new Set([join(wire, 'a.ts'), join(wire, 'b.ts'), join(wire, 'c.ts'), join(wire, 'd.ts'), join(SRC, 'protocol', 'rpc.ts')])
  const exists = (path: string): boolean => files.has(path)
  const escaped = escapedAmong([
    { file: join(wire, 'a.ts'), specifiers: ['./b.ts'] },
    { file: join(wire, 'c.ts'), specifiers: ['../protocol/rpc.ts'] },
    { file: join(wire, 'd.ts'), specifiers: ['node:fs', 'zod'] },
  ], wire, exists)
  assert.deepEqual(
    escaped.map(e => `${e.file.endsWith('c.ts') ? 'c' : e.file.endsWith('d.ts') ? 'd' : 'a'} ${e.specifier}`),
    ['c ../protocol/rpc.ts', 'd zod'],
    'only the escaping ones are reported, with files identified',
  )
})

test('the file reader descends into subdirectories', () => {
  // `src/` 眼下是扁平的，于是「递归」这条能力在判据里用不到 —— 但也正因为用不到，
  // 把它改成只看顶层不会有任何判据变红。这里用 `tests/`（有子目录）把能力本身钉住：
  // 将来 `wire/` 下分了子目录，递归就已经是验过的了。
  //
  // 扫 `tests/` 而不是它的父目录：父目录还装着 `node_modules/` 与 `tsconfig.json`，
  // 那两者与「递归」这条能力无关，却会让「只有 .ts」那一半变成对环境的断言。
  // 本文件就在 `tests/` 下，所以「自己的目录」就是那个有子目录的样本。
  const found = filesUnder(dirname(fileURLToPath(import.meta.url)))
  assert.ok(found.every(file => file.endsWith('.ts')), 'only TypeScript files')
  assert.ok(
    found.some(file => file.includes(`${sep}protocol${sep}`)),
    'a nested file must be found — a top-level-only reader would miss it',
  )
})

test('the two directory entries actually report on a directory that has something to report', () => {
  // 零命中型判据的死穴：入口失效与判据通过长得一样。所以入口本身要在**真目录**上
  // 证一次活性 —— 那批判据是「wire 不许跨出去」，这里反过来用「protocol 确实跨出去」
  // 证明扫描器还看得见东西。少了这一条，把 `outgoingImports` 改成恒返回空数组，
  // V1/V2/V3 会一起变绿而没人发现。
  const fromProtocol = outgoingImports(join(SRC, 'protocol'))
  assert.ok(fromProtocol.length > 0,
    'protocol/ imports wire/ and ports/, so the escaping judge must report something — an empty answer here means the judge is blind')
  assert.ok(fromProtocol.some(e => e.target?.includes(`${sep}wire${sep}`)),
    'and the reported targets must point where the imports actually go')

  // 环检测的入口同理：wire/ 内部有多条边，扫出空图就是失明。
  const graph = importGraph(join(SRC, 'wire'))
  assert.ok(graph.size > 0, 'the graph must have nodes — an empty graph makes the cycle judge vacuous')
  assert.ok([...graph.values()].some(targets => targets.length > 0),
    'and it must have edges — `mux` imports `rpc` and `usage`, so an edge-less graph means the reader is blind')
})

test('the graph keeps only intra-directory edges, and resolves lazy specifiers', () => {
  const wire = join(SRC, 'wire')
  const files = new Set([join(wire, 'a.ts'), join(wire, 'b.ts'), join(wire, 'c.ts'), join(SRC, 'protocol', 'rpc.ts')])
  const graph = graphAmong([
    { file: join(wire, 'a.ts'), specifiers: ['./b.ts', '../protocol/rpc.ts', 'node:fs'] },
    { file: join(wire, 'b.ts'), specifiers: ['./a'] },       // 无扩展名也要成为一条边
    { file: join(wire, 'c.ts'), specifiers: [] },
  ], wire, (path: string) => files.has(path))
  assert.deepEqual(graph.get(join(wire, 'a.ts')), [join(wire, 'b.ts')], 'only the sibling edge survives')
  assert.deepEqual(graph.get(join(wire, 'b.ts')), [join(wire, 'a.ts')], 'extension-less specifier resolves to the real file')
  assert.deepEqual(firstCycle(graph), [join(wire, 'a.ts'), join(wire, 'b.ts'), join(wire, 'a.ts')],
    'and the loop those edges form is found — this is the only thing keeping V4 honest')
})

test('an unresolvable import is an error, not a silently dropped edge', () => {
  // 同样依赖两个真文件；缺了就说清前提，别让它伪装成「判据不灵」。
  requireFiles([join(SRC, 'wire', 'mux.ts'), join(SRC, 'wire', 'rpc.ts')])
  // 环检测与跨目录判定都靠「目标是谁」。解析不出来就说出来，别当成没有依赖 ——
  // 静默丢边只会让零命中型判据更绿。
  assert.throws(
    () => resolutionOf(join(SRC, 'wire', 'mux.ts'), './no-such-file.ts'),
    /cannot resolve/,
  )
  // 反过来：`./rpc`（无扩展名）指得到同一个真文件，必须归一化到它 ——
  // 否则环检测会把这两条边当成图外节点丢掉。
  const canonical = resolutionOf(join(SRC, 'wire', 'mux.ts'), './rpc.ts')
  assert.equal(resolutionOf(join(SRC, 'wire', 'mux.ts'), './rpc'), canonical, 'extension-less resolves')
  assert.equal(canonical, join(SRC, 'wire', 'rpc.ts'), 'and it resolves to the real file')
  // `.js` 说明符**不**映射到 `.ts`：本仓的 import 一律写 `.ts`（Node 的类型剥离直接跑源码）。
  // 若哪天工具链要求 `.js` 后缀，这条会红 —— 那时再决定是支持映射还是改全仓写法。
  assert.throws(
    () => resolutionOf(join(SRC, 'wire', 'mux.ts'), './rpc.js'),
    /cannot resolve/,
    'a .js specifier is not silently rewritten to .ts',
  )
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
  const wire = join(SRC, 'wire')
  // 按**解析后的目标**判，不看 specifier 的字符串前缀：`'../wire/../upstream/x.ts'`
  // 前缀像 wire/，实际落在 upstream/。
  const escaped = outgoingImports(join(SRC, 'ports')).filter(({ target }) => target === undefined || !within(target, wire))
  assert.deepEqual(escaped, [],
    `ports/ is the assembly boundary: it may import wire/ (its signatures name wire types) and nothing else:\n${format(escaped)}`)
})

// ---------------------------------------------------------------------------
// V2b：判定层的依赖面 —— 只经装配边界与共守形状认识世界
// ---------------------------------------------------------------------------

test('protocol/ only reaches into wire/ and ports/', () => {
  const allowed = [join(SRC, 'wire'), join(SRC, 'ports')]
  const escaped = outgoingImports(join(SRC, 'protocol'))
    .filter(({ target }) => target === undefined || !allowed.some(directory => within(target, directory)))
  assert.deepEqual(escaped, [],
    `the protocol layer judges messages; it must not know any transport or host adapter:\n${format(escaped)}`)
})

/**
 * 内建模块在跨目录判定里是放行的（`node:crypto` 之类合法），所以 HTTP 那三个要单独挡：
 * 「判定不认识 HTTP」不会因为它们恰好是内建而自动成立。
 */
/** 某个目录里点名 HTTP 的 import。判据本体在这儿，自证也调它 —— 不调它，「自证」只是自说自话。 */
export function httpImportsAmong(
  units: readonly { file: string; specifiers: readonly string[] }[],
): string[] {
  return units.flatMap(({ file, specifiers }) => specifiers
    .filter(specifier => HTTP_MODULES.has(specifier))
    .map(specifier => `${where(file)} → ${specifier}`))
}

test('protocol/ does not import an HTTP module', () => {
  const offenders = httpImportsAmong(unitsUnder(join(SRC, 'protocol')))
  assert.deepEqual(offenders, [],
    'status codes and request bodies belong to remote/ — a judge that names HTTP is a transport')
})

/** `node:` 前缀与裸写两种形态都算 —— 与 `isBuiltinModule` 认的一样宽。 */
const HTTP_MODULES: ReadonlySet<string> = new Set([
  'node:http', 'node:https', 'node:net', 'node:http2',
  'http', 'https', 'net', 'http2',
])

// ---------------------------------------------------------------------------
// V2c：信封只在判定层构造
// ---------------------------------------------------------------------------

/**
 * 源码里手写协议信封的地方 —— 同一个对象字面量的**顶层**同时有 `v:` 与 `ok:` 键。
 *
 * 为什么不按 `/\{[^{}]*\}/` 找：信封里套着 `error: { code, message }`，那个内层
 * 花括号会让正则只能匹配到内层，外层永远配不上 —— 实测把
 * `{ v, ok: false, error: { … } }` 注回 `remote/http.ts` **零命中**。所以这里按
 * 括号深度扫描：先把每个成对的 `{}` 取出来，再看它自己顶层的键。
 *
 * 已知边界（刻意的）：字符串没剥离。远程目录里出现一个"长得像信封"的字符串会
 * 假红 —— 可以接受，假红有人来看，假绿没人知道。
 */
export function envelopeLiteralsIn(source: string): string[] {
  const code = stripComments(source)
  const found: string[] = []
  const open: number[] = []
  for (let i = 0; i < code.length; i += 1) {
    if (code[i] === '{') open.push(i)
    else if (code[i] === '}' && open.length > 0) {
      const start = open.pop() as number
      const body = code.slice(start, i + 1)
      const keys = topLevelKeysOf(body)
      if (keys.includes('v') && keys.includes('ok')) found.push(body.replace(/\s+/g, ' ').slice(0, 80))
    }
  }
  return found
}

/** 一个对象字面量**自己那一层**的键名（不进嵌套的括号）。 */
function topLevelKeysOf(body: string): string[] {
  const keys: string[] = []
  let depth = 0
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i]
    if (ch === '{' || ch === '(' || ch === '[') depth += 1
    else if (ch === '}' || ch === ')' || ch === ']') depth -= 1
    else if (depth === 1) {
      const match = /^([A-Za-z_$][\w$]*)\s*:/.exec(body.slice(i))
      if (match !== null && match[1] !== undefined) keys.push(match[1])
    }
  }
  return keys
}

test('transport does not build protocol envelopes by hand', () => {
  // 为什么需要这一条：「判定值只有一个家」那张表只列 `protocol/` 的导出，而
  // 第二份构造器是 `remote/` 里的私有函数 —— 表看不见它。R15 期3 之前
  // `remote/http.ts` 就有一份 `refusal()`，与 `failure()` 逐字同义；版本号或
  // 信封字段升一次，两份就会分叉，而手机端只认其中一份。
  const offenders = filesUnder(join(SRC, 'remote')).flatMap(file =>
    envelopeLiteralsIn(readFileSync(file, 'utf8')).map(literal => `${where(file)}: ${literal}`))
  assert.deepEqual(offenders, [],
    `the envelope has two fixed fields and one home (protocol/rpc.ts 的 failure / success):\n${offenders.join('\n')}`)

  // 活性断言：扫描器自己得看得见信封。拿判定层那个真构造器作正控 ——
  // 少了这一条，扫描器瞎了与「没人手写」长得一样（F2 记的那类缺陷）。
  const control = envelopeLiteralsIn(readFileSync(join(SRC, 'protocol', 'rpc.ts'), 'utf8'))
  assert.ok(control.length >= 2,
    `the scanner must see the real constructors in protocol/rpc.ts — found ${control.length}`)
})

// ---------------------------------------------------------------------------
// V3：面向宿主的适配层不认识传输层
// ---------------------------------------------------------------------------

test('upstream/ does not import remote/', () => {
  const remote = join(SRC, 'remote')
  const escaped = outgoingImports(join(SRC, 'upstream')).filter(({ target }) => target !== undefined && within(target, remote))
  assert.deepEqual(escaped, [],
    `the host adapter must not know the transport — a port it needs belongs in ports/:\n${format(escaped)}`)
})

test('upstream/ does not import protocol/', () => {
  const protocol = join(SRC, 'protocol')
  const escaped = outgoingImports(join(SRC, 'upstream')).filter(({ target }) => target !== undefined && within(target, protocol))
  assert.deepEqual(escaped, [],
    `the host adapter meets the judgements only through ports/ — importing protocol/ welds the two layers:\n${format(escaped)}`)
})

// ---------------------------------------------------------------------------
// E6：上游 `$events` 身份只有一个持有者
// ---------------------------------------------------------------------------

/**
 * 源码里**调用**上游开流门的地方：`x.openWireStream(`（成员调用）。
 *
 * 为什么不认「这个标识符出现几次」：装配处有一句
 * `openWireStream: (endpoint, payload, signal) => …`（把门装成对象成员）、一句
 * `` `openWireStream=${typeof raw.openWireStream}` ``（日志文案），还有接口里的
 * `openWireStream(` 声明 —— 三处都不是「又开了一条流」。而「谁在开流」问的是
 * **调用点**，所以只认带点号的那一种。
 *
 * 两侧边界都是刻意的：字符串里写成的调用会被算进来（假红，有人会看一眼改掉）；
 * 把门取个别名再调（`const open = g.openWireStream`）它认不出（假绿）——
 * 后一半由下面的端点字面量判据兜住：第二份身份必须自己把 `'$events'` 写出来。
 */
export function openerCallsIn(source: string): number {
  return stripComments(source).match(/\.openWireStream\s*\(/g)?.length ?? 0
}

/** 源码里把 `$events` 写成一整个字符串字面量的地方（不含 `'$events/result'`）。 */
export function eventEndpointIn(source: string): string[] {
  return [...stripComments(source).matchAll(/(['"`])\$events\1/g)].map(match => match[0])
}

test('the identity scanners tell a call and an endpoint apart from a member read and a neighbour endpoint', () => {
  assert.equal(openerCallsIn("await gateway.openWireStream('$events', { args: {} }, signal)"), 1)
  assert.equal(openerCallsIn('const opening = raw.openWireStream'), 0, 'a member read is not a call')
  assert.equal(openerCallsIn('const members = `openWireStream=${typeof raw.openWireStream}`'), 0,
    'a log line quoting the member opens nothing')
  assert.equal(openerCallsIn('// 旧的写法：gateway.openWireStream(\n'), 0, 'a comment opens nothing')

  assert.deepEqual(eventEndpointIn("open('$events')"), ["'$events'"])
  assert.deepEqual(eventEndpointIn('open("$events")'), ['"$events"'])
  assert.deepEqual(eventEndpointIn("dispatchRpc('$events/result')"), [],
    'the answer door is a different endpoint — it is not the identity')
  assert.deepEqual(eventEndpointIn('// 宿主的 $events 流\n'), [], 'a comment is not an identity')
})

test('the upstream $events identity has exactly one holder', () => {
  // 宿主的挂起问题会投给**每一个** owner 客户端：两份身份会让同一份审批各存一遍，
  // 而症状（手机上的卡片消失又出现、应答报 unknown-approval）离成因很远。
  const callers = filesUnder(SRC).flatMap(file => {
    const count = openerCallsIn(readFileSync(file, 'utf8'))
    return count === 0 ? [] : [`${where(file)}: ${count}`]
  })
  assert.deepEqual(callers, ['upstream/remote-events.ts: 1'],
    'exactly one module opens $events, and it is the one that owns the identity')

  const endpoints = filesUnder(SRC).flatMap(file => {
    const found = eventEndpointIn(readFileSync(file, 'utf8'))
    return found.length === 0 ? [] : [`${where(file)}: ${found.length}`]
  })
  assert.deepEqual(endpoints, ['upstream/remote-events.ts: 1'],
    'so exactly one module may name the endpoint — a second one is a second identity')
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
  { file: 'mux.ts', name: 'openRequestOf', shape: 'OpenRequest' },
  { file: 'model.ts', name: 'modelSelectRequestOf', shape: 'ModelSelectMessage' },
  { file: 'command.ts', name: 'commandExecuteRequestOf', shape: 'CommandExecuteMessage' },
  { file: 'write.ts', name: 'approvalAnswerOf', shape: 'ApprovalAnswerMessage' },
  { file: 'write.ts', name: 'sessionPromptOf', shape: 'SessionPromptMessage' },
  { file: 'write.ts', name: 'sessionCreateTargetOf', shape: 'SessionCreateTarget' },
  { file: 'workspace.ts', name: 'workspaceNameOf', shape: 'WorkspaceCreatePayload' },
  { file: 'workspace.ts', name: 'workspaceIdOf', shape: 'WorkspaceDeletePayload' },
]

/**
 * `wire/` 允许导出的**字段规则** —— 判「这个字段能不能当某种值用」的纯函数。
 *
 * 它们是 codec 之间重复的零件被提出来共享的结果：字段校验本来就是编解码的一部分，
 * 所以这不是 `wire/` 承诺之外的第三类东西，只是不必在每个 codec 里抄一遍。
 *
 * 与 codec 表的两处差别，正是它们能防住的东西：
 *  - 不配形状（一个字段规则配不上任何单一形状 —— 硬配就是编造）；
 *  - **必须至少被一个 codec 用到**。只加规则不加消费者，等于把这里变成
 *    「以后可能会用」的收纳盒，而那种东西没有任何判据在守。
 */
const WIRE_FIELD_GUARDS: readonly { file: string; name: string }[] = [
  { file: 'fields.ts', name: 'nonEmptyString' },
  { file: 'fields.ts', name: 'isPositiveInteger' },
]

/**
 * `wire/` 下允许的导出面 —— **白名单式**，认不出的写法直接抛错。
 *
 * 为什么不用「找函数声明的正则」：那种写法只认它想到的形态，`export { f }`、
 * `export default`、`export const f = x => …`、generator、工厂调用全都能静默绕过 ——
 * 而 V5 是零命中型判据，绕过之后它更绿。
 *
 * 三层防线，每层堵一类绕过：
 *  ① **扫全文所有 `export`**，不只行首 —— 否则 `const a = 1; export function evil()` 溜过去。
 *  ② **语句按括号深度取全**，不只首行 —— 否则 `export const X = { run: () => 1 }` 只看首行 `{` 就放行。
 *  ③ **常量只认字面量**：数字 / 字符串 / 数组 / 对象字面量。标识符与调用都报错 ——
 *     前者说不清是不是函数别名（`export const w = windowArm` 就是算法借道），
 *     后者可能是工厂返回的函数，还带加载期副作用。
 *
 * 要支持新形态，先改这里，别让它静默变成「没有导出函数」。
 *
 * **重导出也被拒，这是有意的**：`export type { X } from './y.ts'` 会让「这个文件的
 * 导出面」变得含糊 —— 哪些是它声明的、哪些只是转发，读代码的人分不出，而本判据
 * 要的正是「导出面 == 白名单」这句话能逐字成立。要转出别处的名字，先想清楚它该
 * 住在哪个文件。
 */
export function exportSurfaceOf(
  source: string,
  options: { allowClasses?: boolean } = {},
): { functions: string[]; shapes: string[]; classes: string[] } {
  const code = stripComments(source)
  const functions: string[] = []
  const shapes: string[] = []
  const classes: string[] = []
  for (const statement of exportStatementsOf(code)) {
    // class 默认不允许：`wire/` 只装形状与编解码，一个 class 就是行为。
    // 判定层则允许（`LogNotDenseError` 这类错误类型），所以它是选项而不是硬规则。
    const classMatch = /^export\s+class\s+([A-Za-z_$][\w$]*)/.exec(statement)
    if (classMatch?.[1] !== undefined) {
      if (options.allowClasses !== true) {
        throw new Error(
          'unsupported export form in wire/ — a class carries behaviour, not a shape: '
          + statement.slice(0, 70),
        )
      }
      classes.push(classMatch[1])
      continue
    }
    let match = /^export\s+interface\s+([A-Za-z_$][\w$]*)/.exec(statement)
    if (match?.[1] !== undefined) {
      shapes.push(match[1])
      continue
    }
    match = /^export\s+type\s+([A-Za-z_$][\w$]*)/.exec(statement)
    if (match?.[1] !== undefined) {
      shapes.push(match[1])
      continue
    }
    match = /^export\s+(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/.exec(statement)
    if (match?.[1] !== undefined) {
      functions.push(match[1])
      continue
    }
    if (/^export\s+const\b/.test(statement)) {
      assertLiteralConstant(statement)
      continue
    }
    throw new Error(
      `unsupported export form in wire/ — extend exportSurfaceOf() first: ${statement.slice(0, 70)}`,
    )
  }
  return { functions, shapes, classes }
}

/**
 * 从 `start`（一个引号）跳到它闭合之后。
 *
 * 模板字符串里的 `${…}` 要按**代码**处理：那里面可以有嵌套模板与引号（本仓的
 * `` `${x === undefined ? 'no x' : \`no \`x\` (${y})\`}` `` 就是这种）。不认插值的话，
 * 嵌套模板的开头会被当成本层的收尾 —— 扫描器从那里起在「代码」与「字符串」之间
 * 翻了个面，之后整段文件的注释与 import 判定全错位（实测：`faces.ts` 的一句
 * log.warn 之后，注释里的 `` `$events` `` 被算成了代码）。
 * 那种失明的方向是**假绿**（判据看不见本该看见的东西），比假红贵。
 */
function skipString(code: string, start: number): number {
  const quote = code[start] as string
  let i = start + 1
  while (i < code.length) {
    if (code[i] === '\\') {
      i += 2
      continue
    }
    if (quote === '`' && code[i] === '$' && code[i + 1] === '{') {
      i = skipInterpolation(code, i + 2)
      continue
    }
    if (code[i] === quote) return i + 1
    i += 1
  }
  return i
}

/** `${` 之后的那段代码，扫到与它配对的 `}` 之后；沿途的字符串（含嵌套模板）跳过。 */
function skipInterpolation(code: string, start: number): number {
  let depth = 1
  let i = start
  while (i < code.length) {
    const ch = code[i] as string
    if (ch === "'" || ch === '"' || ch === '`') {
      i = skipString(code, i)
      continue
    }
    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) return i + 1
    }
    i += 1
  }
  return i
}

/** 一条语句的结束位置：括号平衡处的 `;` 或换行。字符串里的括号与冒号不算。 */
function statementEnd(code: string, start: number): number {
  let depth = 0
  let i = start
  while (i < code.length) {
    const ch = code[i] as string
    if (ch === "'" || ch === '"' || ch === '`') {
      i = skipString(code, i)
      continue
    }
    if (ch === '(' || ch === '{' || ch === '[') depth += 1
    else if (ch === ')' || ch === '}' || ch === ']') depth -= 1
    else if (depth === 0 && (ch === ';' || ch === '\n')) break
    i += 1
  }
  return i
}

/**
 * 全文所有 `export` 语句的文本（从 `export` 起到括号平衡处的 `;` 或换行）。
 *
 * 三件事必须同时做到，否则判据会读错：
 *  ① **跳过字符串** —— 字符串里的 `export` 不是导出，字符串里的 `(` 也不是括号；
 *  ② **不只看行首** —— `const m = 1; export function evil(){}` 的导出也要被看见；
 *  ③ **按深度取全** —— 跨行的对象字面量与形参表都要读进来。
 */
function exportStatementsOf(code: string): string[] {
  const statements: string[] = []
  let i = 0
  while (i < code.length) {
    const ch = code[i] as string
    if (ch === "'" || ch === '"' || ch === '`') {
      i = skipString(code, i)
      continue
    }
    const boundary = i === 0 || !/[\w$]/.test(code[i - 1] as string)
    if (boundary && code.startsWith('export', i)) {
      const end = statementEnd(code, i)
      statements.push(code.slice(i, end).trim())
      i = end
      continue
    }
    i += 1
  }
  return statements
}

/**
 * 常量初始化只认字面量 —— **白名单式**：剥掉所有字符串、对象键与 `true/false/null`
 * 之后，值里**不允许再剩任何标识符**。
 *
 * 为什么不能枚举禁止形态：`= windowArm`、`= { run: windowArm }`、`= true && windowArm`、
 * `= marker = 1, pageWindow = windowArm` 都是「一行合法常量带走一个函数」，而每一轮
 * 枚举都会漏掉下一种。反过来问「剩下的是不是只剩数字与标点」只有一个答案。
 */
function assertLiteralConstant(statement: string): void {
  const match = /^export\s+const\s+[\p{ID_Start}$][\p{ID_Continue}$]*\s*(?::[^=]+)?=\s*([\s\S]*)$/u.exec(statement)
  // 末尾的 `as const` 是标准写法（把字面量类型收窄），剥掉再看形状。
  const value = (match?.[1]?.trim() ?? '').replace(/\s+as\s+const\s*$/, '')
  if (value === '') throw new Error('`export const … =` has no value — extend exportSurfaceOf() first')

  // **先剥字符串**，再做任何判断。否则 `= 'a => b'` 会被当成箭头函数 —— 假红会让人
  // 关掉判据，比漏判更贵。
  const withoutStrings = value.replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`\\]|\\.)*`/g, '""')
  // 函数值的早期形态：好让报错直接教人怎么改。
  if (withoutStrings.trimStart().startsWith('(') || /^\s*(async\b|function\b|<)/.test(withoutStrings)
    || withoutStrings.includes('=>')) {
    throw new Error(
      '`export const … =` looks like a function value — write it as `export function` so the codec table can see it',
    )
  }
  // 剥对象键（`{ key:` / `, key:`）与三个无副作用的词，然后要求**一个标识符都不剩**。
  // 字符类用 `\p{ID_Start}`：CJK 之类非 ASCII 标识符与 ASCII 一样能藏函数，
  // 只按 `[A-Za-z_$]` 找会漏（`export const arm = { run: 窗口 }` 就是这么溜过去的）。
  const withoutKeys = withoutStrings.replace(/(^|[{,])\s*[\p{ID_Start}$][\p{ID_Continue}$]*\s*:/gu, '$1')
  const withoutKeywords = withoutKeys.replace(/\b(true|false|null|undefined)\b/g, '')
  const leftover = withoutKeywords.match(/[\p{ID_Start}$][\p{ID_Continue}$]*/u)
  if (leftover !== null) {
    throw new Error(
      `\`export const … =\` still mentions \`${leftover[0]}\` — a bare identifier could be a function in disguise: ${value.slice(0, 40)}`,
    )
  }
  // 到这一步只剩数字与标点。**形状**仍需是字面量：数字、字符串、数组、对象、布尔/null。
  // 不放行 `new X()`、正则、`satisfies`、类型断言 —— 判据读不懂它们，就不猜；
  // 真要在 wire/ 里写，先扩展这里（一句话的事，但不能默默放行）。
  const shape = withoutKeywords.trim()
  const isKeywordLiteral = shape === '' // 整值是 true / false / null / undefined
  if (!isKeywordLiteral && !/^(\d|-\.?\d|""|\[|\{)/.test(withoutStrings.trim())) {
    throw new Error(
      `\`export const … =\` is not a literal this judge understands — extend assertLiteralConstant(): ${value.slice(0, 40)}`,
    )
  }
}

test('the export-surface reader refuses forms it cannot classify', () => {
  // 每一条都是一次「静默绕过」的真实形态：判据要么认出它，要么报错 ——
  // 绝不能当成「没有导出函数」，那样 V5 会因为看不见它而变绿。
  const mustRefuse: [string, string][] = [
    ['function pageWindow() {}\nexport { pageWindow }', '本地具名导出'],
    ['export default function pageWindow() {}', 'default 导出'],
    ['export const pageWindow = events => events', '单参箭头'],
    ['export const pageWindow = <T>(events: T) => events', '泛型箭头'],
    ['export const pageWindow = makeWindow()', '工厂调用'],
    ['export class PageWindow {}', 'class'],
    ['function windowArm() {}\nexport const pageWindow = windowArm', '标识符别名（算法借道）'],
    ['export const pageWindow = { run: () => 1 }', '对象里藏箭头函数'],
    ['export const pageWindow = [\n  function () {},\n]', '数组里藏函数表达式'],
    ['function windowArm(a: number): number { return a + 1 }\nexport const marker = 1, pageWindow = windowArm', '多声明符里夹带别名'],
    ['function windowArm(a: number): number { return a + 1 }\nexport const pageWindow = { run: windowArm }', '对象值里的裸标识符'],
    ['function windowArm(a: number): number { return a + 1 }\nexport const pageWindow = true && windowArm', '运算符表达式里的别名'],
    ['function 窗口(a: number): number { return a + 1 }\nexport const arm = { run: 窗口 }', '非 ASCII 标识符藏函数'],
  ]
  for (const [source, why] of mustRefuse) {
    assert.throws(
      () => exportSurfaceOf(source),
      /unsupported export form|looks like a function value|still mentions|is not a literal|has no value/,
      `must not slip through (${why}): ${source.replace(/\n/g, ' ')}`,
    )
  }
  // 正控：允许的形态都要认得出，**行中的 export 也要被看见**。
  assert.deepEqual(
    exportSurfaceOf([
      'export interface A { x: number }',
      'export type B = string',
      'export function c(): void {}',
      'export async function d(): Promise<void> {}',
      'export function* e(): Generator<number> {}',
      'export const F = 50',
      "export const G: readonly string[] = ['a']",
      "export const H = 'x('",  // 字符串里的括号不是调用
      "export const I = 'a => b'",  // 字符串里的箭头也不是函数
      'const marker = 1; export function i(): void {}',
      'export const J = { depth: 2 }',
    ].join('\n')),
    { functions: ['c', 'd', 'e', 'i'], shapes: ['A', 'B'], classes: [] },
    'the allowed forms are classified, including an export that is not at line start',
  )
})

test('wire/ exports shapes, codecs and field guards — each accounted for', () => {
  const actual: { file: string; name: string }[] = []
  const shapeNames = new Set<string>()
  const sources = new Map<string, string>()
  for (const path of filesUnder(join(SRC, 'wire'))) {
    const source = readFileSync(path, 'utf8')
    const file = path.slice(path.lastIndexOf(sep) + 1)
    sources.set(file, source)
    const surface = exportSurfaceOf(source)
    for (const name of surface.functions) actual.push({ file, name })
    for (const shape of surface.shapes) shapeNames.add(shape)
  }
  const allowed = [...WIRE_CODECS.map(c => c.name), ...WIRE_FIELD_GUARDS.map(g => g.name)]
  assert.deepEqual(actual.map(f => f.name).sort(), [...allowed].sort(),
    'a function that is neither a codec (pairs with a shape) nor a field guard (used by a codec) belongs elsewhere')

  // 表里两列都要真的成立，否则它们只是注释：`file` 说它在哪个文件，`shape` 说它服务哪个形状。
  const misplaced = WIRE_CODECS.filter(codec => !actual.some(f => f.name === codec.name && f.file === codec.file))
    .map(codec => `${codec.name} 不在 ${codec.file}`)
  assert.deepEqual(misplaced, [], `a codec must live in the file the table names: ${misplaced.join('; ')}`)

  const missing = WIRE_CODECS.filter(codec => !shapeNames.has(codec.shape))
    .map(codec => `${codec.name} → ${codec.shape}`)
  assert.deepEqual(missing, [],
    `each codec must name a shape that wire/ actually exports: ${missing.join(', ')}`)

  // 字段规则的两个方向都要查：位置在表里说的那个文件，且**有人用**。
  // 「有没有第二处」与「有没有人用」是两件事 —— 只查前者，一条没人引用的规则
  // 照样绿（R15 期3 的教训）。
  const guardMisplaced = WIRE_FIELD_GUARDS
    .filter(guard => !actual.some(f => f.name === guard.name && f.file === guard.file))
    .map(guard => `${guard.name} 不在 ${guard.file}`)
  assert.deepEqual(guardMisplaced, [], `a field guard must live in the file the table names: ${guardMisplaced.join('; ')}`)

  const unused = WIRE_FIELD_GUARDS
    .filter(guard => !fieldGuardsImportedBy(sources).has(guard.name))
    .map(guard => guard.name)
  assert.deepEqual(unused, [],
    `a field guard nobody imports is a holding pen, not a shared part: ${unused.join(', ')}`)

  // 第三个方向：**副本回潮**。上面三条查的是导出面，而私有副本不在导出面里 ——
  // 抄一份回 `mux.ts` 之后上面三条全绿（实测过）。所以名字要单独再查一遍：
  // 除 `fields.ts` 外，`wire/` 里任何文件都不得再声明同名标识符。
  const copies = [...sources]
    .filter(([file]) => file !== 'fields.ts')
    .flatMap(([file, source]) => WIRE_FIELD_GUARDS
      .filter(guard => declarationOf(guard.name).test(source))
      .map(guard => `${file}: ${guard.name}`))
  assert.deepEqual(copies, [],
    `a field guard is declared once, in fields.ts — a private copy drifts silently: ${copies.join('; ')}`)
})

/**
 * 一个标识符的**声明**形态：`function f(`、`const f =`、`let` / `var` 同形。
 *
 * 三条规则的名字是固定的闭集，所以这里按名字找声明是够的 —— 不同于「枚举这门语言
 * 能怎么写函数」那类判定（那种永远会漏）。名字在这里就是它自己要防的东西。
 */
function declarationOf(name: string): RegExp {
  return new RegExp(`\\b(?:function\\s*\\*?\\s*|const|let|var)\\s+${name}\\b`, 'u')
}

/**
 * `wire/` 里除 `fields.ts` 自身之外，各文件从 `./fields.ts` 具名导入的规则。
 *
 * 认不出的写法（`import * as`、动态 import、只用字符串拼出来的 specifier）**抛错**：
 * 这一条是「有没有人用」的判据，静默跳过会让没用到的规则显得有人用 ——
 * 与 F2 记的那类「扫描器瞎了但判据绿」同一个病。
 */
function fieldGuardsImportedBy(sources: ReadonlyMap<string, string>): Set<string> {
  const names = new Set<string>()
  for (const [file, source] of sources) {
    if (file === 'fields.ts') continue
    if (!source.includes('fields.ts')) continue
    if (/\bimport\s*\*/.test(source)) throw new Error(`${file}: namespace import is not classifiable`)
    const matches = [...source.matchAll(/import\s+(?:type\s+)?\{([^}]*)\}\s+from\s+['"][^'"]*fields\.ts['"]/gu)]
    // 提到了 fields.ts 却没有一条认得出的具名导入 ⇒ 有人在用别的写法（或只剩注释）。
    if (matches.length === 0 && /from\s+['"][^'"]*fields\.ts['"]/u.test(source)) {
      throw new Error(`${file}: an import of fields.ts that is not a plain named import`)
    }
    for (const match of matches) {
      for (const part of match[1]!.split(',')) {
        const name = part.trim().replace(/^type\s+/u, '').split(/\s+as\s+/u)[0]!.trim()
        if (name.length > 0) names.add(name)
      }
    }
  }
  return names
}


// ---------------------------------------------------------------------------
// V6：源码注释不指向开发工作区
// ---------------------------------------------------------------------------

test('no source comment points into the workspace docs', () => {
  // 扫 `src/` 与**本文件**：产品代码的注释是给仓库读者看的，指向不发布的文档就是死链；
  // 判据自身也不该示范它禁止的写法。
  //
  // 其余测试文件不在扫描面，因为那里的工作区路径是**它们的题材**而不是出处 —— 术语检查
  // 要说明它扫哪四份活文档，那不是「注释只给出处」。这条边界写在代码里，免得下一次有人
  // 把它当成漏扫补上，然后不得不加一套豁免机制。
  const self = fileURLToPath(import.meta.url)
  const files = [...filesUnder(SRC), self]
  const offenders: string[] = []
  for (const file of files) {
    for (const span of commentSpans(readFileSync(file, 'utf8'))) {
      if (/\bdev\//.test(span.text)) offenders.push(`${where(file)}: ${span.text.trim().slice(0, 90)}`)
    }
  }
  assert.deepEqual(offenders, [],
    'workspace docs are not published — a comment that only points at them is a dead link to repo readers')
})

// ---------------------------------------------------------------------------
// V6b：README 里点名的源文件必须真的存在
// ---------------------------------------------------------------------------

test('every source file the gateway README names still exists', () => {
  // README 是仓库读者打开这个目录看到的第一个文件，它画的是两条请求链。链条上
  // 每个文件名都是一次改名就会静默变假的事实 —— 而注释与文档没有编译器管。
  // 这条只查「文件在不在」：链条的**顺序**没有机械判据（那要读实现），
  // 但「指向不存在的文件」是可判的，也是最常见的漂移形态。
  //
  // 三种写法都要认，否则读者与判据对同一个名字的理解可以不一致：
  //   `src/index.ts`   —— 相对包根
  //   `remote/http.ts` —— 相对 src/
  //   `egress.ts`      —— 裸名，此时它必须是全仓**唯一**的，否则这个引用有歧义
  const readme = readFileSync(join(SRC, '..', 'README.md'), 'utf8')
  const all = filesUnder(SRC)
  const named = [...readme.matchAll(/`([A-Za-z0-9_./-]+\.ts)`/g)]
    .map(match => (match[1] as string).replace(/^\.\//, ''))
  assert.ok(named.length > 0, 'the README must name its files — an empty list would make this judge vacuous')

  const problems: string[] = []
  for (const specifier of named) {
    if (specifier.includes('src/')) {
      if (!existsSync(join(SRC, '..', specifier))) problems.push(`${specifier}: no such file relative to the package root`)
      continue
    }
    if (specifier.includes('/')) {
      if (!existsSync(join(SRC, specifier))) problems.push(`${specifier}: no such file under src/`)
      continue
    }
    const hits = all.filter(file => file.endsWith(`${sep}${specifier}`))
    if (hits.length === 0) problems.push(`${specifier}: no file of that name anywhere under src/`)
    else if (hits.length > 1) problems.push(`${specifier}: ambiguous — ${hits.length} files share this name, write the directory too`)
  }
  assert.deepEqual(problems, [],
    `the README must point at files that exist, unambiguously (renamed? update the README in the same commit):\n${problems.join('\n')}`)
})

// ---------------------------------------------------------------------------
// V7：opening 只有一个装配者
// ---------------------------------------------------------------------------

test('the retired second opening assembler name does not come back', () => {
  // 它不缺别的，只缺「后来加的那个字段」：一旦被接线，手机端拿到的基线就永远缺席，
  // 而测试仍全绿（判据只查窗口几何）。装配这件事只能有一个执行者。
  //
  // **只剥注释，不剥字符串。** 剥字符串需要一个认模板插值的词法器 —— 手写的那个
  // 会把 `${…}` 里的代码一起删掉，于是整个文件的后半段对本判据失明（假绿，比假红贵）。
  // 代价是：一个**字面量文本**里出现 `followOpening(` 会假红。这条代价是选过的 ——
  // 假红会有人来看一眼并改掉那句文案；假绿没人会知道。
  //
  // 断言的是**这个名字不再出现**，不是「不存在任何第二装配器」—— 一个叫别的名字的
  // 第二装配器它看不见，这里不假装看得见。
  const offenders = filesUnder(SRC)
    .filter(file => /\bfollowOpening\s*\(/.test(stripComments(readFileSync(file, 'utf8'))))
    .map(where)
  assert.deepEqual(offenders, [],
    'opening is assembled in remote/stream.ts only — the retired assembler omitted fields the wire requires')
})

test('the retired assembler is not exported under any name binding', async () => {
  // 文本扫描之外再加一条运行时断言：哪怕源码里只是一句文案、或者被重导出改了名，
  // 「有模块交出 followOpening 这个值」都能被抓到 —— 这一半不会被字符串骗过。
  const exported = [...(await valueIndex()).get('followOpening') ?? []]
  assert.deepEqual(exported, [], 'no module may hand out an opening assembler besides the one inside remote/stream.ts')
})

// ---------------------------------------------------------------------------
// V9：判定符号只从一个模块导出，且那个模块就是它该在的地方
// ---------------------------------------------------------------------------

/**
 * 这两条判据**不解析语法**，它们问运行时：每个模块到底导出了什么。
 *
 * 为什么不用正则扫声明：`export` 的写法是开放集（`export {x}` / `export default` /
 * `const enum` / `abstract class` / `declare` / 缩进 / 命名空间 / `.mts` …），枚举它
 * 必然漏掉下一种 —— 这条路上已经走过三轮，每轮都被找到新形态。而**模块的导出表是
 * 闭集**：Node 加载完一个模块，`Object.keys(namespace)` 就是它交出的全部名字，
 * 没有第五种写法能绕过去。
 *
 * 两条边界，都是刻意的：
 *
 * ① 只看**导出**。一个声明了同名符号、但不导出的副本看不见 —— 那是死代码，
 *    归 `code-slim-audit`，不归结构判据。
 * ② `declare function handle()` **不算**。`declare` 在编译后什么都不留，运行时没有这个
 *    函数，因此它构不成「第二份实现」—— 调用它会在运行时报 undefined。判据放行它是对的。
 */

/**
 * 判定层的导出面清单。**值**（函数 / 常量 / 类）与**类型**分开列，因为它们的
 * 证据来源不同：
 *
 *   值    运行时真话 —— `Object.keys(namespace)`。闭集，没有语法能绕过。
 *   类型  编译期产物，运行时被擦除，所以只能读源码：`exportSurfaceOf` 是**白名单式**的，
 *         认不出的写法直接抛错（`class` 要显式允许），不会静默当成「没有导出」。
 *
 * 表要覆盖 `protocol/` 的**每一个**导出（下面第二条判据会核对，新加导出不补表就红）。
 * 手法与 `WIRE_CODECS` 同一套：改表这个动作逼人回答「它归哪一层」。
 *
 * `upstream/usage.ts` 是唯一的例外，且是刻意的：`usageSnapshotOf` 认宿主的投影键名
 * （`contextPressure` / `contextBreakdown`），消费者在宿主适配层。放进 `protocol/`
 * 会让 `upstream/` 必须 import `protocol/`（撞 V3）。
 */
const JUDGEMENT_SURFACE: readonly { home: string; values: readonly string[]; types: readonly string[] }[] = [
  {
    home: 'protocol/rpc.ts',
    values: ['DEFAULT_LIMITS', 'DEFAULT_PAGE_MESSAGES', 'handle', 'positiveOrDefault', 'failure', 'success'],
    types: ['Limits'],
  },
  {
    home: 'protocol/window.ts',
    values: ['LogNotDenseError', 'CursorPastEndError', 'pageWindow', 'upstreamWindow', 'fitOpeningToBytes'],
    types: ['OpeningShrink'],
  },
  { home: 'protocol/usage.ts', values: ['usageIsTrigger', 'usageShouldEmit'], types: [] },
  {
    home: 'protocol/error-codes.ts',
    values: ['streamErrorOf', 'readErrorOf'],
    types: ['ProtocolRefusal'],
  },
  {
    home: 'protocol/auth.ts',
    values: [
      'ACCESS_TTL_MS', 'PAIRING_TTL_MS', 'PAIRING_MAX_ATTEMPTS', 'emptyCredentials', 'sha256Hex',
      'newPairingCode', 'newToken', 'bearerTokenOf', 'isPlausiblePairingCode', 'attemptPairing',
      'issueAccess', 'isLiveAccess',
    ],
    types: ['StoredCredentials', 'PairingOutcome'],
  },
  { home: 'upstream/usage.ts', values: ['usageSnapshotOf'], types: [] },
]

/** 一个模块交出的**值** —— 运行时真话，不是从源码里猜的。 */
async function valuesOf(file: string): Promise<string[]> {
  const namespace = await import(pathToFileURL(file).href) as Record<string, unknown>
  return Object.keys(namespace)
}

/** 一个模块交出的**类型** —— 读源码，但走的是会抛错的白名单扫描器。 */
function typesOf(file: string): string[] {
  return exportSurfaceOf(readFileSync(file, 'utf8'), { allowClasses: true }).shapes
}

/** 全 `src/` 的值索引：`名字 → 交出它的文件`。每个模块都要能加载 —— 载不动就是判据失明。 */
async function valueIndex(): Promise<Map<string, string[]>> {
  const index = new Map<string, string[]>()
  for (const file of filesUnder(SRC)) {
    for (const name of await valuesOf(file)) {
      index.set(name, [...(index.get(name) ?? []), relative(SRC, file)])
    }
  }
  return index
}

/** 一个文件里有哪些类型导出。 */
function typeIndexIn(file: string): Set<string> {
  return new Set(typesOf(join(SRC, file)))
}

/** 一个符号是否只在它该在的那个文件交出，且只交一次。 */
function homeComplaints(kind: string, index: Map<string, string[]>, wanted: readonly { name: string; home: string }[]): string[] {
  return wanted.flatMap(({ name, home }) => {
    const places = index.get(name) ?? []
    if (places.length === 0) return [`${kind} ${name}: not exported by any module — renamed? then update JUDGEMENT_SURFACE`]
    if (places.length > 1) {
      return [`${kind} ${name}: offered by ${places.join(', ')} — a second copy will silently stop being updated`]
    }
    const [only] = places
    return only === home ? [] : [`${kind} ${name}: comes from ${String(only)}, expected ${home}`]
  })
}

test('each judgement value comes from exactly one module, at its stated home', async () => {
  const wanted = JUDGEMENT_SURFACE.flatMap(({ home, values }) => values.map(name => ({ name, home })))
  assert.deepEqual(homeComplaints('value', await valueIndex(), wanted), [],
    'a judgement value reachable from two modules, or from the wrong one, makes the layer boundary a lie')
})

test('each judgement type is declared in the file that owns it', () => {
  // 只查「在不在它该在的那个文件里」，**不假装查全仓唯一**：类型是编译期产物，
  // 而全仓类型扫描必须容下 `export { … }` 这类合法列表，一放宽就回到开放集枚举 ——
  // 那正是前面三轮翻车的地方。危险的那一半（第二份**实现**）由上面那条值判据守。
  const complaints = JUDGEMENT_SURFACE.flatMap(({ home, types }) => {
    const present = typeIndexIn(home)
    return types.filter(name => !present.has(name))
      .map(name => `type ${name}: not declared in ${home} — renamed or moved?`)
  })
  assert.deepEqual(complaints, [],
    'a judgement type that left its file leaves the layer boundary describing something that is gone')
})

test('every export of protocol/ is listed as a judgement symbol', async () => {
  // 没有这一条，新增判定符号时不会有人想起补表 —— 上面两条只查表里已有的名字，
  // 名单会和 protocol/ 的实际面越差越远。
  const listed = new Set(JUDGEMENT_SURFACE.flatMap(({ values, types }) => [...values, ...types]))
  const unlisted: string[] = []
  for (const file of filesUnder(join(SRC, 'protocol'))) {
    for (const name of [...await valuesOf(file), ...typesOf(file)]) {
      if (!listed.has(name)) unlisted.push(`${where(file)}: ${name}`)
    }
  }
  assert.deepEqual(unlisted, [],
    'a new export in protocol/ needs a home in JUDGEMENT_SURFACE — otherwise nothing stops a second copy of it')
})

test('the export index sees the modules it is supposed to see', async () => {
  // 活性正控：索引若因为加载失败或路径写错变成空表，上面几条判据会「全绿」。
  const values = await valueIndex()
  // 具名锚点而不是数字阈值：数字会因为重构漂，锚点只在「那个文件没被读到」时才红。
  // 活性锚：**每个目录都要在索引里留下名字**。不按名字锚（`log.ts` 故意重导出整个
  // perf 模块，按名字锚会误红），按目录锚 —— 要证明的本来就是「走遍了」。
  const walked = new Set([...values.values()].flat())
  for (const directory of ['wire', 'ports', 'protocol', 'remote', 'upstream']) {
    assert.ok([...walked].some(file => file.startsWith(`${directory}/`)),
      `no name was indexed from ${directory}/ — the walk never read it`)
  }
  assert.ok([...walked].some(file => !file.includes('/')), 'no name was indexed from a top-level file (log.ts, perf.ts)')
  assert.equal(values.has('thisNameDoesNotExistAnywhere'), false)
})

// ---------------------------------------------------------------------------
// V10：传输层按故障域分三段
// ---------------------------------------------------------------------------

/**
 * 传输层的三段各有自己的存活范围：整个进程（连接集合）、一条 socket、一条流。
 * 拆的时候最容易出的错是**成环** —— 连接要起泵（connection → stream），而泵要写一帧
 * （stream → connection）。共享的写出口因此单列（`egress.ts`），它不是第四段。
 */
test('remote/ has no import cycle', () => {
  const cycle = firstCycle(importGraph(join(SRC, 'remote')))
  assert.equal(cycle, undefined,
    `the three transport lifetimes must not depend on each other in a loop: ${cycle?.map(where).join(' → ')}`)
})

test('the RFC framing implementation is reached only from the transport', () => {
  // 成帧跟着它唯一的消费者走：手机端有系统自带的 WebSocket，不用我们这份实现，
  // 所以它不该再挂在「两端共守」的名下。
  const frames = join(SRC, 'remote', 'frames.ts')
  const outsiders = filesUnder(SRC)
    .filter(file => !within(file, join(SRC, 'remote')))
    .flatMap(file => importsOf(readFileSync(file, 'utf8'))
      .filter(specifier => specifier.startsWith('.') && resolutionOf(file, specifier) === frames)
      .map(specifier => `${where(file)} → ${specifier}`))
  assert.deepEqual(outsiders, [], 'framing has one consumer: the transport layer')
})

test('the transport is split by lifetime, and the old single file is gone', () => {
  const directory = join(SRC, 'remote')
  const names = filesUnder(directory).map(file => relative(directory, file)).sort()
  // 三份生命周期各一文件 + 共享出口 + 成帧 + 一元调用 + 凭据保管。
  const expected = [
    'connection.ts', 'credentials.ts', 'egress.ts', 'frames.ts',
    'http.ts', 'server.ts', 'stream.ts',
  ]
  assert.deepEqual(names, expected,
    'ws.ts must be gone: one file cannot show three lifetimes')
})

/**
 * 「可能含声明」的那部分代码：剥注释、剥字符串、去掉 import 与 `export … from`。
 *
 * 两件事必须去掉，否则不产生声明的写法会被当成声明（两种都是**假红**，
 * 而假红会让人把判据关掉）：
 *   ① `import { type PairResponse } from '…'` —— `type` 与名字相邻，但它只是导入；
 *   ② `export type { PairResponse } from '…'` —— 重导出，同样不声明新名字。
 * 字符串也要剥：`"interface PairResponse is …"` 这种文案不是声明。
 */
export function declarationScopeOf(source: string): string {
  return stripComments(source)
    .replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`\\]|\\.)*`/g, '""')
    .replace(/\bimport\b[^;]*?\bfrom\s*""/g, '')
    .replace(/\bimport\s*""/g, '')
    .replace(/\bexport\b[^;]*?\bfrom\s*""/g, '')
}

// ---------------------------------------------------------------------------
// V11：凭据类 op 的形状有唯一出处
// ---------------------------------------------------------------------------

test('the credential ops\' shapes have one declaration and at least one consumer', () => {
  // 这两条 op 绕过统一入口，形状曾经只写在传输层的函数体里 —— 手机端另有一份
  // Swift 声明，两边靠人对齐。现在它们与其余 op 一样住在 wire/。
  //
  // 两条判据缺一不可，因为失败有两种形态：
  //   ① **声明被复制**一份到别处 → 两边各自演进；
  //   ② 声明还留着、但**没人用它**（形状被内联成匿名对象类型）→ 那份声明变成纯文档，
  //      改它不会让任何地方编译失败。只查①会漏掉②，而那正是本期的失败模式。
  const home = join(SRC, 'wire', 'auth.ts')
  const expected = ['PairRequest', 'RefreshRequest', 'PairResponse', 'RefreshResponse']

  const declaredAt = new Map<string, string[]>()
  const mentionedIn = new Map<string, string[]>()
  for (const file of filesUnder(SRC)) {
    const source = readFileSync(file, 'utf8')
    const scope = declarationScopeOf(source)
    const relativePath = relative(SRC, file)
    for (const name of expected) {
      // 类型的声明形态是闭集：`interface X` / `type X` / `class X`，关键字紧邻名字
      // （不管前面挂什么修饰符）。不按「行首有没有 export」判 —— 那是开放集。
      if (new RegExp(`(?:^|[^A-Za-z0-9_$])(?:interface|type|class)\\s+${name}\\b`).test(scope)) {
        declaredAt.set(name, [...(declaredAt.get(name) ?? []), relativePath])
      }
      // 「提到过」用完整源码（含 import）：`import type { X }` 就是一次消费。
      if (new RegExp(`\\b${name}\\b`).test(stripComments(source))) {
        mentionedIn.set(name, [...(mentionedIn.get(name) ?? []), relativePath])
      }
    }
  }

  const complaints = expected.flatMap(name => {
    const places = declaredAt.get(name) ?? []
    const out: string[] = []
    if (places.length === 0) out.push(`${name}: not declared anywhere — renamed?`)
    else if (places.length > 1) out.push(`${name}: declared in ${places.join(', ')} — a second source will drift`)
    else if (places[0] !== 'wire/auth.ts') out.push(`${name}: declared in ${String(places[0])}, expected wire/auth.ts`)
    // 消费者：home 之外至少一个文件提到它。
    const consumers = (mentionedIn.get(name) ?? []).filter(file => file !== 'wire/auth.ts')
    if (consumers.length === 0) out.push(`${name}: nobody uses it — an inline anonymous type is the same split`)
    return out
  })
  assert.deepEqual(complaints, [],
    'each credential shape needs one declaration in wire/auth.ts **and** a consumer that would fail to compile if it changed')

  // 正控：`wire/auth.ts` 的导出面恰好是这四个，多一个就红（防止形状悄悄长出来）。
  assert.deepEqual(exportSurfaceOf(readFileSync(home, 'utf8')).shapes.sort(), [...expected].sort(),
    'and nothing else is declared there')

  // 它们没有编解码器：解析与校验在别的层（见该文件的头注释），所以其函数面必须为空。
  assert.deepEqual(exportSurfaceOf(readFileSync(home, 'utf8')).functions, [],
    'no codec here — validating a pairing code is a rule, not a shape')
})

// ---------------------------------------------------------------------------
// V12：拒绝留痕的豁免表与真实 op 对得上
// ---------------------------------------------------------------------------

/**
 * `handle` 的 switch 认得哪些 op。闭集取自**分派本身**，不是另抄一份名单 ——
 * 第二份名单与第一份一起漂，正是这条判据要防的东西。
 */
function dispatchedOps(): string[] {
  const source = stripComments(readFileSync(join(SRC, 'protocol/rpc.ts'), 'utf8'))
  return [...source.matchAll(/case '([a-z0-9-]+)':/g)].map(match => match[1]!)
}

test('the silent-refusal list only names ops the protocol actually dispatches', async () => {
  // 留痕的默认方向是「失败就记」，所以豁免表是唯一需要人维护的那张。写错的形态很安静：
  // 一个改了名或已删除的 op 留在表里，那一条 op 的失败从此既没有日志、也没人知道它本该静默。
  const ops = dispatchedOps()
  // 活性锚：扫描器若因为正则或路径失效而读空，下面的差集会「通过」。
  for (const op of ['session-prompt', 'command-execute', 'command-catalog', 'model-catalog']) {
    assert.ok(ops.includes(op), `the op scan did not even see "${op}" — it is reading nothing`)
  }

  const module = await import(pathToFileURL(join(SRC, 'remote/http.ts')).href) as {
    SILENT_REFUSALS?: ReadonlySet<string>
  }
  const silent = module.SILENT_REFUSALS
  assert.ok(silent instanceof Set, 'SILENT_REFUSALS must be an exported Set — otherwise this judge reads nothing')

  assert.deepEqual([...silent].filter(op => !ops.includes(op)), [],
    'a silent-refusal entry that names no dispatched op protects nothing and hides the next drift')
})

// ---------------------------------------------------------------------------
// 审批帧：每个 kind 只构造一次，装配层不拼帧
// ---------------------------------------------------------------------------

/**
 * 两种审批货物（`waterfall` / `cancel`）各自**只有一个构造点**，且都在 `remote/stream.ts`；
 * `wire/mux.ts` 里的是形状**声明**，不是构造。
 *
 * 守的是「第二处顺手拼一帧」这个真实风险 —— 中继曾经自己组帧，往一处加字段、另一处忘掉，
 * 两份代码相距很远、长得却几乎一样，评审看不出来。
 *
 * 数的是**次数**不是文件：同一文件里的第二处构造不该因为「文件没变」就放行。
 * 判据按期望值断言，不是零命中。
 */
test('each approval kind is constructed exactly once, where the stream pump lives', () => {
  const constructionHome = 'remote/stream.ts'
  const declarationHome = 'wire/mux.ts'
  const seen = new Map<string, { file: string; count: number }[]>()
  for (const file of filesUnder(SRC)) {
    const code = stripComments(readFileSync(file, 'utf8'))
    for (const kind of ['waterfall', 'cancel'] as const) {
      const hits = [...code.matchAll(new RegExp(`kind:\\s*'${kind}'`, 'g'))].length
      if (hits === 0) continue
      seen.set(kind, [...(seen.get(kind) ?? []), { file: where(file), count: hits }])
    }
  }

  // 活性锚：一份都没扫到说明路径或正则失效，下面的比较会「通过」。
  assert.equal(seen.size, 2, `the scan found no approval kinds at all — got ${JSON.stringify([...seen.keys()])}`)

  for (const [kind, homes] of seen) {
    const constructors = homes.filter(home => home.file === constructionHome)
    const declarers = homes.filter(home => home.file !== constructionHome)
    assert.equal(constructors.reduce((total, home) => total + home.count, 0), 1,
      `\`kind: '${kind}'\` must be constructed exactly once, in ${constructionHome} — got ${JSON.stringify(homes)}`)
    assert.deepEqual(declarers.map(home => home.file), [declarationHome],
      `\`kind: '${kind}'\` is declared in ${declarationHome} and constructed in ${constructionHome} — a third home is a second constructor`)
  }
})

/**
 * 连接级 `approval` 帧不许回来。
 *
 * 它是「同一件事两种投递形态」的另一半：一旦有人加回一条不带 `streamId` 的帧，客户端就得
 * 再长出第二个消费入口，而两端的判据各自都是绿的 —— 各守自己那半边，中间那一跳没人守。
 *
 * 零命中判据必须自带活性锚：扫错目录、正则失效、文件没读到，读出来都是零命中。
 * 这里的锚是**同一批文件里必须还能看见审批货物**。
 */
test('A3: the connection-level approval frame is gone for good', () => {
  let scanned = 0
  let cargoes = 0
  const hits: string[] = []
  for (const file of filesUnder(SRC)) {
    scanned += 1
    const code = stripComments(readFileSync(file, 'utf8'))
    if (code.includes("kind: 'waterfall'")) cargoes += 1
    if (code.includes("type: 'approval'")) hits.push(where(file))
  }
  assert.ok(scanned > 40, `only scanned ${scanned} source files — the root is wrong`)
  assert.ok(cargoes > 0, 'no approval cargo found at all — the scan sees nothing, so "zero hits" proves nothing')
  assert.deepEqual(hits, [], `the connection-level approval frame is back in ${hits.join(', ')}`)
})

/**
 * 每条服务端帧都说得出自己属于哪条流。
 *
 * 判据的失败形态是 **typecheck 红**，不是断言红：往联合里加一个没有 `streamId` 的成员，
 * `streamIdOf` 这一行就编译不过（`npm test` 先跑 typecheck，所以它照样挡得住）。
 * 这也是「第二种投递形态」唯一能在形状层挡住的地方。
 */
const streamIdOf = (frame: MuxServerFrame): StreamId => frame.streamId

test('A4: every server frame names the stream it belongs to', () => {
  assert.equal(streamIdOf({ type: 'end', streamId: 's1' }), 's1')
  assert.equal(streamIdOf({ type: 'error', streamId: 's2', payload: { code: 'x', message: '' } }), 's2',
    'if a member ever loses `streamId`, this file stops compiling — that is the judge')
})

/**
 * 广播能力删掉了，资源采样没被误伤。
 *
 * 两半各守一个方向：`broadcast(` 回来等于又出现「不指定流、发给所有人」的投递；
 * `clientCount` 没了等于删广播时把采样一起带走（那是另一件事，不该一起死）。
 */
test('L2: broadcast is gone and clientCount survived it', () => {
  const files = filesUnder(SRC)
  assert.ok(files.length > 40, `only scanned ${files.length} source files`)
  const hits = files.filter(file => /\bbroadcast\s*\(/.test(stripComments(readFileSync(file, 'utf8'))))
  assert.deepEqual(hits.map(where), [],
    'a connection-wide broadcast is back — delivery belongs to a stream, not to whoever is connected')

  const server = stripComments(readFileSync(join(SRC, 'remote/server.ts'), 'utf8'))
  assert.ok(server.includes('clientCount'), 'clientCount went missing with the broadcast — the sampler lost its input')
})

/**
 * 审批应答不借流的上行。
 *
 * 上行只有一条路（HTTP 一元 op），流是单向的推。给一条流加一种「应答货物」会让同一次应答
 * 有两个入口，而两个入口的失败处置至今不同（一元 op 有错误回包，流里没有）。
 */
test('L6: approval answers never travel on a stream', () => {
  const streamFiles = filesUnder(join(SRC, 'remote'))
  assert.ok(streamFiles.length >= 3, `only scanned ${streamFiles.length} transport files`)
  for (const file of streamFiles) {
    const code = stripComments(readFileSync(file, 'utf8'))
    assert.equal(code.includes('approval-answer'), false,
      `${where(file)} carries the answer op — answers are one-way ops, not stream cargo`)
  }
  // 活性锚：应答确实还在 HTTP 分派那一侧 —— 两边都没有，说明这个名字改了。
  const dispatch = stripComments(readFileSync(join(SRC, 'protocol/rpc.ts'), 'utf8'))
  assert.ok(dispatch.includes("case 'approval-answer'"),
    'the dispatcher no longer owns approval-answer — the judge is looking at the wrong name')
})

// ---------------------------------------------------------------------------
// G3：上游的事件名不出适配层
// ---------------------------------------------------------------------------

/**
 * `api-session/` 是上游的词汇。它只允许出现在两处：适配层（`upstream/`，那里负责
 * 把它翻成我们的形状）与 `wire/` 的注释之外 —— 判据扫的是**字符串字面量**，
 * 所以注释里解释「上游叫什么」不会红。
 *
 * 守的是「客户端与传输层都不认识上游事件名」这条立场：一旦 `remote/` 或 `protocol/`
 * 里出现它，就有人在第二个地方解释上游，而那一处我们控制不了上游的漂移。
 */
test('G3: upstream session event names live only in the upstream adapter', () => {
  const expected = ['upstream/session-events.ts']
  const homes = new Map<string, number>()
  for (const file of filesUnder(SRC)) {
    const code = stripComments(readFileSync(file, 'utf8'))
    const hits = [...code.matchAll(/'api-session\/[a-z]+'/g)].length
    if (hits > 0) homes.set(where(file), hits)
  }

  // 活性锚：一处都没扫到说明路径或正则失效，下面的比较会「通过」。
  assert.ok(homes.size > 0, 'no `api-session/*` literal found at all — the scan is broken')

  assert.deepEqual([...homes.keys()].sort(), expected,
    `upstream event names must live in ${expected.join(' + ')} only — got ${JSON.stringify([...homes.keys()])}`)
})

// ---------------------------------------------------------------------------
// 日志出口唯一
// ---------------------------------------------------------------------------

/**
 * 日志只能从 `log.ts` 出去。
 *
 * 这条纪律一直存在（`RULES` 写了「日志出口唯一：禁裸 `console.*`」），但**从来没有判据** ——
 * 任何人加一句 `console.log` 都不会红，而症状是那一行绕过了级别门控、模块标签与时间戳，
 * 混在输出里谁也认不出来源。
 *
 * 判据落在 `src/` 的**代码**上，不是原文：注释里出现 `console.log`（本文件就有一处说明）
 * 不该算违规，所以先剥注释再扫。
 */
test('console.* lives only in the logging exit', () => {
  const offenders: string[] = []
  for (const file of filesUnder(SRC)) {
    if (!file.endsWith('.ts')) continue
    if (file === resolve(SRC, 'log.ts')) continue
    const code = stripComments(readFileSync(file, 'utf8'))
    for (const match of code.matchAll(/\bconsole\s*\.\s*(log|error|warn|debug|info)\s*\(/g)) {
      offenders.push(`${where(file)}: ${match[0]}`)
    }
  }
  assert.deepEqual(offenders, [],
    'a log line that bypasses log.ts loses its level, module tag and timestamp — use createLogger instead')
})

test('the console scan would catch a bare line if one appeared', () => {
  // 活性正控：扫的是剥注释后的代码，所以要证明这两件事同时成立 ——
  // 真代码会被抓、注释里的说明不会。
  const sample = [
    '// 说明文字里提到 console.log，不该算违规',
    'const log = createLogger("x")',
    'console.log("bare")',
  ].join('\n')
  const code = stripComments(sample)
  assert.equal([...code.matchAll(/\bconsole\s*\.\s*log\s*\(/g)].length, 1,
    '剥注释后应当只剩那一句真代码')
})
