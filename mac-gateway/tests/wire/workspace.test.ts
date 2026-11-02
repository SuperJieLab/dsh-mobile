/**
 * 工作空间名字的规则与请求判型。
 *
 * 规则只有一张表：trim 之后非空、不含路径分隔符、不是 `.` 或 `..`。客户端有一份
 * 同样的实现（`ios/tests/WorkspaceNameTests.swift` 跑同一组样本）—— 因为它要在
 * 提交前就拦下、不发请求；而服务端不信任客户端，所以这一份也不可省。
 *
 * 两份实现靠同一组字面量对齐，不靠「记得同步」。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { workspaceNameOf } from '../../src/wire/workspace.ts'

/** 与 iOS 侧逐字相同的一组样本。加样本时两边一起加。 */
const REFUSED = ['', '   ', 'a/b', 'a\\b', '.', '..', ' a/b ']
const ACCEPTED = ['记账 App', 'a b', '.config', '项目-1', 'test-r41']

/** 「这个名字能不能用」只有这一个公开答案 —— 规则本身不导出（结构判据守着 `wire/` 的导出面）。 */
const accepts = (name: string): boolean => workspaceNameOf({ name }) !== undefined

test('the name rule refuses blanks, separators and the two dot entries', () => {
  for (const name of REFUSED) {
    assert.equal(accepts(name), false, `「${name}」应当被拒`)
  }
})

test('the name rule accepts spaces inside, dot-prefixed and non-ASCII names', () => {
  for (const name of ACCEPTED) {
    assert.equal(accepts(name), true, `「${name}」应当被接受`)
  }
})

test('the name rule trims before judging, so a padded separator is still refused', () => {
  assert.equal(accepts('  a/b  '), false, '首尾空白不得把分隔符藏起来')
  assert.equal(accepts('  ok  '), true)
})

test('the payload reader yields the trimmed name and refuses a malformed payload', () => {
  assert.equal(workspaceNameOf({ op: 'workspace-create', name: '  记账  ' }), '记账',
    '名字要先 trim 再交给下游 —— 否则磁盘上的名字带空格、界面上的不带')
  for (const payload of [{}, { name: '' }, { name: 42 }, { name: 'a/b' }, 'workspace-create', null]) {
    assert.equal(workspaceNameOf(payload), undefined,
      `载荷 ${JSON.stringify(payload)} 该被拒：形状与语义在同一个判断里`)
  }
})
