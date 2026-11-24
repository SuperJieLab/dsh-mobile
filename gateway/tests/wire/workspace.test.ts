/**
 * 工作空间两条写 op 的请求判型。
 *
 * 创建只认**路径**（宿主按路径注册一个已存在的目录），删除只认 id。两者都读宿主的
 * `request` 容器 —— 少一层就是旧客户端的形状，按畸形拒。
 *
 * 名字规则不在这里：标题由宿主从路径取，客户端与网关都不判「名字」。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { workspaceIdOf, workspacePathOf } from '../../src/wire/workspace.ts'

test('the create reader yields the host path verbatim', () => {
  assert.equal(workspacePathOf({ request: { path: '/Users/x/proj' } }), '/Users/x/proj')
  // 路径**一字不改**：首尾空格、中文、点开头都可能是真实目录名的一部分。
  assert.equal(workspacePathOf({ request: { path: '  /Users/x/记账 App  ' } }), '  /Users/x/记账 App  ',
    '不 trim、不改大小写、不折叠分隔符 —— 路径不是用户输入的名字')
})

test('the create reader refuses a payload without a usable path', () => {
  for (const payload of [
    {},
    // 少一层容器 = 旧客户端（它的字段一格都没送到）。
    { path: '/Users/x' },
    { request: null },
    { request: [] },
    { request: {} },
    { request: { path: '' } },
    { request: { path: '   ' } },
    { request: { path: 42 } },
    { request: { path: null } },
  ]) {
    assert.equal(workspacePathOf(payload), undefined,
      `载荷 ${JSON.stringify(payload)} 该被拒 —— 写路径从严，不靠下游兜`)
  }
})

test('the create reader does not judge whether the path exists or is absolute', () => {
  // 存在性、可读写、是否绝对路径都是宿主的事（它有 `workspace/*` 与 `directory-picker/*` 的码）。
  assert.equal(workspacePathOf({ request: { path: 'relative/dir' } }), 'relative/dir')
  assert.equal(workspacePathOf({ request: { path: '/nope/not/here' } }), '/nope/not/here')
})

// -- 删除载荷 ---------------------------------------------------------------

test('the delete payload reader yields a non-empty workspace id', () => {
  assert.equal(workspaceIdOf({ request: { workspaceId: 'w-a' } }), 'w-a')
})

test('the delete payload reader refuses a payload without a usable id', () => {
  for (const payload of [
    {},
    // 少一层容器 = 旧客户端：它的字段一格都没送到，不能当「没指定」收下。
    { workspaceId: 'w-a' },
    { request: null },
    { request: [] },
    { request: {} },
    { request: { workspaceId: '' } },
    { request: { workspaceId: '   ' } },
    { request: { workspaceId: 42 } },
    { request: { workspaceId: null } },
  ]) {
    assert.equal(workspaceIdOf(payload), undefined,
      `载荷 ${JSON.stringify(payload)} 该被拒 —— 写路径从严，不靠下游兜`)
  }
})

test('the delete payload reader does not judge whether the workspace exists', () => {
  assert.equal(workspaceIdOf({ request: { workspaceId: '从来没见过的-id' } }), '从来没见过的-id',
    '存在与否是宿主的事；删一个不存在的按成功处理，所以这一层不该先拦')
})
