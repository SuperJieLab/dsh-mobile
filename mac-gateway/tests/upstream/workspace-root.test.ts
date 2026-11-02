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
