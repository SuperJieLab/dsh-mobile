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

import { describeError } from '../ports/errors.ts'
import { createLogger, LogModule } from '../log.ts'

const execFileAsync = promisify(execFile)
const log = createLogger(LogModule.workspace)

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
  const startedAt = Date.now()
  let stdout: string
  try {
    stdout = await run('osascript', [
      '-e',
      'POSIX path of (path to documents folder from user domain without folder creation)',
    ])
  } catch (error) {
    // 超时是这条链**最需要留痕**的降级：`osascript` 首次调用会弹 macOS 的自动化授权框，
    // 用户没点就永远不返回。它与其他失败在报错文本上分不开（都是一个 Error），
    // 只有这里有上下文能说清是「超时」还是「命令本身失败」—— 两者的排查方向相反。
    if (timedOut(error)) {
      log.warn(
        'asking the system for Documents timed out — the automation prompt may still be waiting',
        { ms: LOOKUP_TIMEOUT_MS },
      )
    }
    throw error
  }
  const documents = stdout.trim()
  if (documents === '') {
    throw new Error('the system Documents directory resolved to an empty path')
  }
  const root = join(documents, WORKSPACE_ROOT_SEGMENT)
  // 成功也留一句：只有失败日志的话，分不清「没走到这一步」与「走到了但后面错了」。
  // 耗时一并给出 —— 首次要等授权框时，它与平时的毫秒级差得很远。
  log.info('root resolved', { ms: Date.now() - startedAt, root })
  return root
}

/** `execFile` 超时的指纹：被信号杀掉。 */
function timedOut(error: unknown): boolean {
  const shape = error as { killed?: unknown; signal?: unknown } | null
  return shape?.killed === true && typeof shape.signal === 'string'
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
  try {
    await mkdir(path, { recursive: true })
  } catch (error) {
    // 带上路径：同一个 op 里前面还有「问系统要根」那一步，只说「建目录失败」对不上是哪一层。
    log.warn('mkdir failed', { path, error: describeError(error) })
    throw error
  }
}
