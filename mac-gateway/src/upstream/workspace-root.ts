/**
 * 工作空间的固定根，以及在那之下造一个目录。
 *
 * 根由**系统**回答，不由我们假定：`osascript` 问出 Documents 的真实位置，再拼上本应用
 * 那一段。这与宿主首次使用时用的那条命令是同一条 —— 两端据此落在同一个父目录，
 * 用户在 Finder 里找得到、Web UI 侧栏里也看得见。
 *
 * 问不出来就抛错，**绝不退回 `~/Documents`**：猜一个位置会把项目建到用户找不到的地方。
 *
 * 名字由 `wire/workspace.ts` 判过才进来，这里不再判。
 */

import { execFile } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

/** 本应用在 Documents 下占的那一段。与宿主首次使用时用的是同一个名字。 */
export const WORKSPACE_ROOT_SEGMENT = 'deepseek-harness'

/**
 * 问系统要目录的时限。
 *
 * 首次调用 `osascript` 会触发 macOS 的自动化授权确认 —— 那个对话框挂着不点、或用户拒了
 * 但进程没退，`execFile` 会一直等下去。没有上限就等于「这一次请求既不给 ok 也不给
 * internal-error」，而契约承诺的是两条失败之一。10 秒比人手点一下确认宽得多。
 */
export const LOOKUP_TIMEOUT_MS = 10_000

/** 跑一条系统命令并返回 stdout。抽出来是为了让判据不必真的起子进程。 */
export type CommandRunner = (command: string, args: readonly string[]) => Promise<string>

/** 建一个目录（含中间层）。默认即 `mkdir -p` 的语义。 */
export type DirectoryMaker = (path: string) => Promise<void>

/** 可替换的两处系统交互；缺省走真实现。 */
export interface WorkspaceRootDeps {
  run?: CommandRunner
  mkdir?: DirectoryMaker
}

/**
 * 问系统要 Documents 目录，拼出固定根。**不创建任何东西。**
 *
 * @param deps - 可替换的系统交互。
 * @returns 绝对路径，以本应用那一段结尾。
 */
export async function workspaceRoot(deps: WorkspaceRootDeps = {}): Promise<string> {
  const run = deps.run ?? runCommand
  const documents = (await run('osascript', [
    '-e',
    'POSIX path of (path to documents folder from user domain without folder creation)',
  ])).trim()
  if (documents === '') {
    throw new Error('the system Documents directory resolved to an empty path')
  }
  return join(documents, WORKSPACE_ROOT_SEGMENT)
}

/**
 * 在固定根下建出 `<根>/<名字>`。
 *
 * 用 recursive：根目录本身可能还不存在（用户从没用过宿主的工作空间功能），而目录已存在
 * 也不算错 —— 那正是「同名重来一次」的情形。
 *
 * @param name - 已判过的名字（单段、非空）。
 * @param deps - 可替换的系统交互。
 * @returns 建出来的绝对路径。
 */
export async function makeWorkspaceDirectory(
  name: string,
  deps: WorkspaceRootDeps = {},
): Promise<string> {
  const path = join(await workspaceRoot(deps), name)
  await (deps.mkdir ?? makeDirectory)(path)
  return path
}

async function runCommand(command: string, args: readonly string[]): Promise<string> {
  const { stdout } = await execFileAsync(command, [...args], { timeout: LOOKUP_TIMEOUT_MS })
  return stdout
}

async function makeDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true })
}
