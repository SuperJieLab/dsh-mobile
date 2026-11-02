/**
 * 工作空间快照：组清单与归属表都从注册表来，各自只有一处来源。
 *
 * 这一层只问「注册表的成员表被翻译成了什么」：清单保序、归属逐条对得上。
 * 宿主怎么建那份索引（realpath、符号链接、大小写）是它的事 —— 我们不再实现一遍。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { workspaceSnapshotOf } from '../../src/upstream/workspace.ts'

/**
 * 一个工作空间在注册表里的样子。`path` 是**多余的**：实现要是改成按目录路径
 * 与会话的 cwd 比对，这里一个 cwd 也没有，归属表会空 —— 下面那条断言就是它的守护。
 */
function workspace(id: string, title: string, sessionIds: readonly string[]) {
  return { id, title, sessionIds, path: `/w/${id}` }
}

test('snapshot keeps the registry order and maps every member to its workspace', () => {
  const snapshot = workspaceSnapshotOf({
    list: () => [workspace('w-b', 'B 项目', ['s2']), workspace('w-a', 'A 项目', ['s1', 's3'])],
  })

  assert.deepEqual(snapshot.rows, [
    { id: 'w-b', title: 'B 项目' },
    { id: 'w-a', title: 'A 项目' },
  ], '组清单必须原样保留注册表的顺序 —— 按标题或按 id 重排都会在这里红')
  assert.equal(snapshot.owners.get('s1'), 'w-a')
  assert.equal(snapshot.owners.get('s3'), 'w-a')
  assert.equal(snapshot.owners.get('s2'), 'w-b')
  assert.equal(snapshot.owners.get('s9'), undefined, '不在任何成员表里的会话没有归属')
})

test('an empty registry yields an empty snapshot rather than throwing', () => {
  const snapshot = workspaceSnapshotOf({ list: () => [] })

  assert.deepEqual(snapshot.rows, [])
  assert.equal(snapshot.owners.size, 0)
})
