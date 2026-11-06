/**
 * 宿主（dsh）的版本 —— 这个网关是对着哪一版上游写的。
 *
 * 为什么需要它：上游是 alpha，API 会漂（`openWireStream` 从 3 个参数变成 6 个这种事
 * 发生过）。漂了之后网关的表现不是「版本不对」，是「某个方法不是函数」—— 排查方向
 * 完全错。基线记在文档里靠人记，而文档不会在启动时说话。
 *
 * **只警告，不阻止启动**：上游发一个小版本就起不来，是比「可能漂了」更坏的交换。
 * 而且大部分漂移与我们无关 —— 真正相关的面很窄，让日志说一句就够。
 */
import { readFileSync, realpathSync } from 'node:fs'
import { dirname, join } from 'node:path'

/**
 * 写这个网关时**核对过源码**的宿主版本。
 *
 * 不是「运行时最新版」—— 是「我们真的读过它 API 形状的那一版」。两者不同时，
 * 这个差异就该被报出来：它意味着新版本的 API 没人看过。把常量改成运行时的版本
 * 会让警告消失，而那份安心是假的。
 */
export const BUILT_AGAINST = '0.2.2-alpha.3'

/** 宿主包的名字。npx 缓存里是带 scope 的那个，也认不带 scope 的。 */
const HOST_NAMES: Set<string> = new Set(['@deepseek-ai/dsh', 'dsh'])

/**
 * 从进程入口向上找宿主的 `package.json`，读出它的 `version`。
 *
 * 网关零依赖、宿主不装进我们的 `node_modules`，所以 `require.resolve` 那条路走不通 ——
 * 唯一稳的线索是 `process.argv[1]`（dsh 的入口）。找不到就返回 `undefined`：
 * **读不到版本不该让网关起不来**。
 *
 * **入口要先解软链**：npx 执行的是 `node_modules/.bin/dsh`，它软链到
 * `@deepseek-ai/dsh/lib/bin.js`，而 `argv[1]` 保留软链那一侧的路径。从 `.bin` 向上走
 * 到不了宿主的 `package.json` —— 那在 `.bin` 的兄弟目录里，不在祖先链上。不解这一步，
 * 症状就是「读不到」而不是「读错了」，看起来像宿主没装。
 *
 * @param argv1 - 进程入口；可注入以便判据造一棵假的目录树。
 */
export function hostVersionOf(argv1: string | undefined = process.argv[1]): string | undefined {
  if (argv1 === undefined || argv1 === '') return undefined

  // 解不开就按原样走：入口可能是个不存在于磁盘的路径（判据会这么造）。
  let entry = argv1
  try {
    entry = realpathSync(argv1)
  } catch {
    // 保留原路径。
  }

  let directory = dirname(entry)
  // 最多上溯 6 层：npx 缓存是 `_npx/<hash>/node_modules/@deepseek-ai/dsh/lib/bin.js`。
  for (let step = 0; step < 6; step += 1) {
    const manifest = join(directory, 'package.json')
    try {
      const parsed = JSON.parse(readFileSync(manifest, 'utf8')) as {
        name?: unknown
        version?: unknown
      }
      // 名字对得上才算 —— 沿途会经过 `node_modules` 下别人的 package.json，
      // 拿第一个就当宿主会读到完全无关的版本。
      if (typeof parsed.name === 'string' && HOST_NAMES.has(parsed.name)
          && typeof parsed.version === 'string' && parsed.version !== '') {
        return parsed.version
      }
    } catch {
      // 这一层没有 package.json（或不是 JSON），继续往上。
    }
    const parent = dirname(directory)
    if (parent === directory) break
    directory = parent
  }
  return undefined
}

/** 一次比对的结果。三态，不是「匹配或不匹配」—— 读不到是第三种。 */
export type HostCheck =
  | { kind: 'unknown' }
  | { kind: 'match'; version: string }
  | { kind: 'differs'; host: string; builtAgainst: string }

/**
 * 比对。**严格相等**：alpha 之间也可能不兼容，宁可多报一句警告。
 *
 * @param host - 宿主实际版本；`undefined` = 读不到。
 * @param builtAgainst - 网关对着写的版本。
 */
export function checkHostVersion(
  host: string | undefined,
  builtAgainst: string = BUILT_AGAINST,
): HostCheck {
  if (host === undefined) return { kind: 'unknown' }
  if (host === builtAgainst) return { kind: 'match', version: host }
  return { kind: 'differs', host, builtAgainst }
}
