/**
 * 工作空间的固定根：从系统问到 Documents 在哪，再拼上本应用那一段。
 *
 * 这一层只答两件事：根是哪条路径、目录建在哪里。它不认识注册表，也不判名字 ——
 * 名字由 `wire/workspace.ts` 判过才进来。
 *
 * 判据里最要紧的一条是**失败不兜底**：问不出 Documents 就抛错，绝不退回 `~/Documents`。
 * 猜一个位置会把项目建到用户找不到的地方，而那种错不会立即显形。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { makeWorkspaceDirectory, workspaceRoot } from '../../src/upstream/workspace-root.ts'
import { setLogSink } from '../../src/log.ts'

test('the root is the system Documents directory plus our own segment', async () => {
  const asked: string[] = []
  const root = await workspaceRoot({
    run: async (command, args) => {
      asked.push(`${command} ${args.join(' ')}`)
      return '/Users/someone/Documents\n'
    },
  })

  assert.equal(root, '/Users/someone/Documents/deepseek-harness',
    '根必须落在系统的 Documents 下、与本应用那一段拼起来')
  assert.equal(asked.length, 1, '只该问系统一次')
  assert.match(asked[0], /^osascript /,
    '要问系统 Documents 在哪，而不是假定 ~/Documents —— 上游用的是同一条命令')
})

test('a failed lookup throws instead of guessing a fallback', async () => {
  await assert.rejects(
    workspaceRoot({ run: async () => { throw new Error('osascript is unavailable') } }),
    /osascript is unavailable/,
    '问不出系统目录时必须失败：退回 ~/Documents 会把项目建到用户找不到的地方',
  )
})

test('an empty answer is a failure, not an empty path', async () => {
  await assert.rejects(() => workspaceRoot({ run: async () => '  \n' }))
})

test('the directory is created under the root and its absolute path comes back', async () => {
  const made: string[] = []
  const path = await makeWorkspaceDirectory('记账 App', {
    run: async () => '/Users/someone/Documents\n',
    mkdir: async target => { made.push(target) },
  })

  assert.equal(path, '/Users/someone/Documents/deepseek-harness/记账 App')
  assert.deepEqual(made, [path], '只建这一个目录')
})

test('no directory is made when the root cannot be resolved', async () => {
  const made: string[] = []
  await assert.rejects(() => makeWorkspaceDirectory('proj', {
    run: async () => { throw new Error('no documents') },
    mkdir: async target => { made.push(target) },
  }))

  assert.deepEqual(made, [], '根都没解析出来就不该碰文件系统')
})

// -- 留痕 -------------------------------------------------------------------

/**
 * 这一组判据守的是**日志**，不是返回值。
 *
 * 它们值得存在的理由：`osascript` 首次调用会弹 macOS 的自动化授权框，用户没点就超时 ——
 * 而超时与「命令本身失败」在报错上分不开（都是一个 Error），两者的排查方向还相反。
 * 整条链路里只有这里能说清是哪一种；这句话不写出来，用户报「建工作空间没反应」时
 * 日志里查不到任何东西。
 */
function captureLogs(): { lines: string[]; restore: () => void } {
  const lines: string[] = []
  const previous = setLogSink((_level, module, line) => { lines.push(`${module}|${line}`) })
  return { lines, restore: () => { setLogSink(previous) } }
}

/** `execFile` 超时抛出来的那个形状：被信号杀掉。 */
function timeoutError(): Error {
  return Object.assign(new Error('Command failed: osascript'), {
    killed: true, signal: 'SIGTERM',
  })
}

test('a timed-out lookup says so, and an ordinary failure does not', async () => {
  const captured = captureLogs()
  try {
    await assert.rejects(() => workspaceRoot({ run: async () => { throw timeoutError() } }))
    const timedOut = captured.lines.filter(line => line.includes('timed out'))
    assert.equal(timedOut.length, 1, '超时必须留一句 —— 它是这条链最容易发生、也最难倒推的失败')
    assert.match(timedOut[0], /^workspace\|/, '要能按模块把它从别的噪音里筛出来')

    captured.lines.length = 0
    await assert.rejects(() => workspaceRoot({ run: async () => { throw new Error('osascript not found') } }))
    assert.equal(captured.lines.filter(line => line.includes('timed out')).length, 0,
      '普通失败不该被说成超时 —— 一个是「去点授权框」，一个是「这台机器没这个命令」')
  } finally {
    captured.restore()
  }
})

test('a successful lookup reports the resolved root', async () => {
  const captured = captureLogs()
  try {
    await workspaceRoot({ run: async () => '/Users/someone/Documents/\n' })
    const resolved = captured.lines.filter(line => line.includes('root resolved'))
    assert.equal(resolved.length, 1,
      '成功也要留一句：只有失败日志时，分不清「没走到这一步」与「走到了但后面错了」')
    assert.match(resolved[0], /deepseek-harness/, '要写清最终那条路径')
  } finally {
    captured.restore()
  }
})

test('an empty answer logs nothing, because it never got as far as a root', async () => {
  const captured = captureLogs()
  try {
    await assert.rejects(() => workspaceRoot({ run: async () => '   \n' }))
    assert.equal(captured.lines.filter(line => line.includes('root resolved')).length, 0,
      '空答案没有根可报 —— 报一条空路径只会让人以为解析成功了')
  } finally {
    captured.restore()
  }
})
