/**
 * `usageIsTrigger`：哪些事件值得重读投影（U5）。
 *
 * 「该发哪一帧」那一半已随 `usage` 帧一起退役 —— 现在由 control 流按 `asOfSeq`
 * 比较前后两份投影，取分子规则在客户端（`UsageView` / `PermissionState`）。
 * 这一层只剩「要不要重读」，所以判据要覆盖**每一条被消费的投影**的触发事件 ——
 * 漏一类不会报错，只会让那一格在别的设备上变了而手机上不动。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { usageIsTrigger } from '../../src/protocol/usage.ts'

test('U5: every event that can move a served projection justifies a re-read', () => {
  for (const type of ['assistant/message', 'assistant/attempt', 'request/context',
    // 权限那一格（`permissions.currentValue`）：切档本身，与它连带写下的两个 knob。
    'permission/preset', 'sandbox/mode', 'approval/policy']) {
    assert.equal(usageIsTrigger({ type }), true, type)
  }
  for (const type of ['tool/call', 'tool/result', 'turn/start', 'turn/end', 'user/message', 'assistant-stream']) {
    assert.equal(usageIsTrigger({ type }), false, type)
  }
})
