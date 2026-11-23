/**
 * 打开帧的字节收窄（`protocol/window.ts` 的 `fitOpeningToBytes`）。
 *
 * 窗口算术本身已不在网关里：`session/follow` 与 `session/page` 都转发宿主的请求，
 * 本文件只剩「一条 WS 消息装不装得下」这一条判定 —— 界由字节定、切点由轮定。
 *
 * Run: node --test tests/protocol/window.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fitOpeningToBytes } from '../../src/protocol/window.ts'
import type { SessionRecord } from '../../src/wire/rpc.ts'

/** 一条窗口记录；它在线上的字节数由夹具自己的尺寸表给出。 */
function event(type: string, seq: number): SessionRecord {
  return { type: 'event', event: { type, seq, time: 1_700_000_000_000 + seq, data: {} } }
}

/**
 * A frame sizer over a literal per-event byte table. The table is the test's own
 * fact — it is not recomputed from the production code — so the expected starts
 * below are arithmetic on numbers written out by hand.
 */
const FRAME_BASE_BYTES = 50
function sizer(sizes: readonly number[]): (start: number) => number {
  return start => FRAME_BASE_BYTES + sizes.slice(start).reduce((sum, size) => sum + size, 0)
}

test('fitOpeningToBytes: keeps the largest suffix that fits, cut on a turn boundary', () => {
  // Three turns of two events each (turn/start then a message). A naive byte cut
  // would land inside a turn; the answer must land on a turn/start.
  const window = [
    event('turn/start', 0), event('user/message', 1),
    event('turn/start', 2), event('user/message', 3),
    event('turn/start', 4), event('user/message', 5),
  ]
  const bytes = sizer([10, 200, 10, 200, 10, 200])
  // cap 300: start 0 → 50+680=730, start 2 → 50+420=470, start 4 → 50+210=260.
  assert.deepEqual(fitOpeningToBytes(window, 300, bytes), { start: 4, cutTurns: 2, cutEvents: 4 })
})

test('fitOpeningToBytes: with no turn boundary to snap to, it cuts on bytes alone', () => {
  const window = [event('user/message', 0), event('user/message', 1), event('user/message', 2)]
  const bytes = sizer([200, 200, 200])
  // No turn/start anywhere: fall back to the largest byte-only suffix (start 2).
  assert.deepEqual(fitOpeningToBytes(window, 300, bytes), { start: 2, cutTurns: 0, cutEvents: 2 })
})

test('fitOpeningToBytes: one turn that still exceeds the cap is refused, not truncated', () => {
  const window = [event('turn/start', 0), event('user/message', 1)]
  const bytes = sizer([10, 1000])
  // The only turn boundary is the current start, and that one turn is over cap.
  // Truncating inside the turn would show half a turn — refuse instead.
  assert.deepEqual(fitOpeningToBytes(window, 300, bytes), { unshrinkable: true })
})

test('fitOpeningToBytes: a window already inside the cap is left untouched', () => {
  const window = [event('turn/start', 0), event('user/message', 1)]
  const bytes = sizer([10, 100])
  assert.deepEqual(fitOpeningToBytes(window, 300, bytes), { start: 0, cutTurns: 0, cutEvents: 0 })
})

test('fitOpeningToBytes: an empty window is untouched, not refused', () => {
  // An empty session opens on an empty window. Having nothing to cut is not the
  // same as failing to fit — the refusal path must not swallow it.
  assert.deepEqual(fitOpeningToBytes([], 300, sizer([])), { start: 0, cutTurns: 0, cutEvents: 0 })
})

test('fitOpeningToBytes: a window whose head is not a turn boundary', () => {
  // 窗口是整份日志、而日志开头不是 `turn/start` 时（前几条事件属于日志头部），
  // 候选起点若只取「第一个 `turn/start`」，**永远不会试 start = 0** —— 装得下也会被
  // 裁到那个边界上，而日志只留一行「narrowed by N events / 0 turns」，看不出是候选漏了。
  const head = [
    event('session/start', 0), event('user/message', 1),
    event('user/message', 2), event('user/message', 3),
  ]
  const window = [...head, event('turn/start', 4), event('user/message', 5)]
  const bytes = sizer([10, 10, 10, 10, 10, 100])

  // ① 整窗装得下（= 真机那一支）：不动它 —— 起点 0 必须在候选里，即便它不在轮边界
  assert.deepEqual(fitOpeningToBytes(window, 100_000, bytes), { start: 0, cutTurns: 0, cutEvents: 0 })

  // ② 装不下：仍吸附到第一个 turn 边界（不是按字节硬切）—— 收窄该发生时照旧发生
  assert.deepEqual(fitOpeningToBytes(window, 180, bytes), { start: 4, cutTurns: 0, cutEvents: 4 })
})
