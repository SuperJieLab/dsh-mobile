/**
 * `list-sessions` 应答里的两样东西：工作空间清单与每行的归属。
 *
 * 这一层只问「清单保序、归属逐条对得上、没有归属时字段缺席」。归属**怎么算**
 * （成员表还是目录路径）是适配器的事，见 `tests/upstream/workspace.test.ts` ——
 * 在这里再验一遍等于把同一件事判两次，而其中一次会先漂。
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'

import { handle } from '../../src/protocol/rpc.ts'
import type { SessionPort } from '../../src/ports/session.ts'
import type { WorkspacePort, WorkspaceSnapshot } from '../../src/ports/workspace.ts'
import type { SessionRow } from '../../src/wire/rpc.ts'

function portWith(rows: readonly SessionRow[]): SessionPort {
  return { list: async () => rows, read: async () => undefined, readAll: async () => undefined }
}

function row(id: string, updatedAt: number): SessionRow {
  return { id, createdAt: 1_758_000_000_000, updatedAt, running: false, blank: false }
}

function workspacePort(snapshot: WorkspaceSnapshot): WorkspacePort {
  return {
    snapshot: () => snapshot,
    // 这一组用例只读列表；写面在这里用不到，走到就是编错了。
    create: async () => { throw new Error('list-sessions must not create a workspace') },
    delete: async () => { throw new Error('list-sessions must not delete a workspace') },
  }
}

/**
 * 只跑 `list-sessions`。`handle` 的通道按位置追加，列表路径只用到前两位 ——
 * 这个包装让每条用例里那句调用只写与本题有关的东西。
 */
function listSessions(port: SessionPort, workspaces?: WorkspacePort) {
  return handle({ v: 2, op: 'list-sessions' }, port, Date.now, undefined, undefined, undefined, undefined, workspaces)
}

interface ListAnswer {
  ok: boolean
  workspaces?: readonly { id: string; title: string }[]
  sessions?: readonly Record<string, unknown>[]
}

test('list-sessions answers the workspace list in the registry order', async () => {
  const answer = await listSessions(
    portWith([row('s1', 2)]),
    workspacePort({
      rows: [{ id: 'w-b', title: 'B 项目' }, { id: 'w-a', title: 'A 项目' }],
      owners: new Map([['s1', 'w-a']]),
    }),
  ) as ListAnswer

  assert.deepEqual(answer.workspaces, [
    { id: 'w-b', title: 'B 项目' },
    { id: 'w-a', title: 'A 项目' },
  ], '组清单原样透出注册表的顺序 —— 客户端据此排组，网关不得重排')
})

test('each row carries its workspace, and a row with none omits the field', async () => {
  const answer = await listSessions(
    portWith([row('s1', 3), row('s2', 2), row('s3', 1)]),
    workspacePort({
      rows: [{ id: 'w-a', title: 'A 项目' }, { id: 'w-b', title: 'B 项目' }],
      owners: new Map([['s1', 'w-a'], ['s2', 'w-b']]),
    }),
  ) as ListAnswer

  const byId = new Map((answer.sessions ?? []).map(session => [session.id, session]))
  assert.equal(byId.get('s1')?.workspaceId, 'w-a')
  assert.equal(byId.get('s2')?.workspaceId, 'w-b')
  assert.deepEqual(Object.keys(byId.get('s3') ?? {}).includes('workspaceId'), false,
    '没有归属时字段必须整个缺席：写成 null 或空串会让客户端多出一个「还不知道」的分支')
})

test('a workspace with no sessions still appears in the list', async () => {
  const answer = await listSessions(
    portWith([row('s1', 1)]),
    workspacePort({ rows: [{ id: 'w-empty', title: '还没说过话' }], owners: new Map() }),
  ) as ListAnswer

  assert.deepEqual(answer.workspaces, [{ id: 'w-empty', title: '还没说过话' }],
    '组清单取自注册表全量，不按「有没有会话」过滤 —— 否则手机上刚建的工作空间无处可寻')
})

test('an empty registry answers an empty array rather than dropping the key', async () => {
  const answer = await listSessions(portWith([]), workspacePort({ rows: [], owners: new Map() })) as ListAnswer

  assert.deepEqual(answer.workspaces, [],
    '「没有工作空间」与「端口没接」在线上必须是两件事：前者是空数组，后者才没有这个键')
})
