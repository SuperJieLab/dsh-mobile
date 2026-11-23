/**
 * 目录读面：网关在这一侧读**宿主机器的文件系统**，给手机的目录浏览器用。
 *
 * 为什么不是留宿主的 `directoryPickerController`：那套 seam 一次只组一种能力 ——
 * `native`（在机器上弹系统选择框，只有 `pick`）或 `browse`（可 `list`）。macOS 的
 * 桌面宿主按启动事实选的是 `native`，于是同一台机器上面向远程的 `list` 根本不存在
 * （`directoryPicker.list needs the browse capability; the composed picker serves "native"`）。
 * 手机点不到机器上的对话框，能用的只有「列出目录」这一种，所以这一条由网关自己实现。
 *
 * 列的是**宿主所在机器的真实目录**：这是网关第一次自己碰文件系统，规则因此写在这里
 * 一处，不散到协议层。产物形状与契约 §4.14 的五格逐字一致 —— 手机只回声，不拼路径。
 */

import { readdir, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import type { DirectoryPort } from '../ports/directory.ts'

/** 一层最多回多少条。手机一屏放不下更多，多了只是让一次请求变慢。 */
const MAX_ENTRIES = 500

/** 列目录时的一条产物 —— 契约 §4.14 的 `entries` / `crumbs` 元素。 */
interface ListingEntry {
  readonly name: string
  readonly path: string
  readonly hidden: boolean
}

/** 契约 §4.14 的应答五格。 */
interface Listing {
  readonly path: string
  readonly home: string
  readonly crumbs: ListingEntry[]
  readonly entries: ListingEntry[]
  readonly truncated: boolean
}

/**
 * 目录读面。`path` 缺省时列 home；给了就必须是绝对路径。
 *
 * @param limit - 一层最多回几条（判据用小值验截断）。
 */
export function directoryListingOver(limit = MAX_ENTRIES): DirectoryPort {
  return {
    list: async (path) => listingOf(path, limit),
  }
}

/**
 * 列一层目录。
 *
 * - 只出**子目录**（文件不在这里选），符号链接指向目录的算目录，断链跳过。
 * - 名字按字节序排 —— 与区域设置无关的那一种，两台机器的顺序才会一样。
 * - 点开头的标 `hidden`，显示与否归客户端（契约里 `hidden` 是给客户端判的字段）。
 * - `path` 归一化一次（去掉 `..` 与结尾斜杠）：面包屑与 `entries[].path` 都由它拼，
 *   不归一化会让同一个目录出现两种写法。
 *
 * 读不到（不存在 / 无权限）直接抛，由协议层折成 `internal-error` —— 与「宿主拒绝」
 * 同一个码，客户端留着一个不能进的目录比拿到一句「读不了」更糟。
 */
async function listingOf(path: string | undefined, limit: number): Promise<Listing> {
  const home = homedir()
  const target = path === undefined ? home : normalise(path)

  const dirents = await readdir(target, { withFileTypes: true })
  const candidates = dirents.filter(dirent => dirent.isDirectory() || dirent.isSymbolicLink())
  const directories: ListingEntry[] = []
  for (const dirent of candidates) {
    const child = join(target, dirent.name)
    // 符号链接：只有真指向目录的才收；断链与指向文件的跳过（不是错误 —— 那个目录
    // 确实不能进，报错会挡住整层）。
    if (dirent.isSymbolicLink()) {
      const stats = await stat(child).catch(() => undefined)
      if (stats?.isDirectory() !== true) continue
    }
    directories.push({ name: dirent.name, path: child, hidden: dirent.name.startsWith('.') })
  }
  directories.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0))

  return {
    path: target,
    home,
    crumbs: crumbsOf(target),
    entries: directories.slice(0, limit),
    truncated: directories.length > limit,
  }
}

/** 一条路径必须能当起点用：绝对、且去掉 `..` 与结尾斜杠。 */
function normalise(path: string): string {
  if (!isAbsolute(path)) {
    throw new Error(`directory path must be absolute: "${path}"`)
  }
  return resolve(path)
}

/**
 * 从文件系统根到这一层的祖先链（含这一层）。
 *
 * 按段拼而不是 `dirname` 回溯：回溯会漏掉根、也会在 `..` 上绕圈。每一格都是客户端
 * 可跳转的目标，所以 `path` 必须是归一化后的绝对路径。
 */
function crumbsOf(target: string): ListingEntry[] {
  const segments = target.split('/').filter(segment => segment !== '')
  const crumbs: ListingEntry[] = [{ name: '/', path: '/', hidden: false }]
  let cursor = ''
  for (const segment of segments) {
    cursor += `/${segment}`
    crumbs.push({ name: segment, path: cursor, hidden: segment.startsWith('.') })
  }
  return crumbs
}
