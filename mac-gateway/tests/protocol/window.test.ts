/**
 * 反向窗口算术（`protocol/window.ts`）：规则本身的直接判据、两载体共用的拼法，
 * 以及窗口之后的字节收窄（open 必须装得进客户端的一条消息上限）。
 *
 * `page` 与流 opening 走这条算术的行为另有端到端覆盖；本文件钉的是算术本体 ——
 * 包括它自己的两种拒绝与边界，那些经 `page` 只能看到错误码、看不到是哪一支持有的判断。
 * Run: node --test tests/protocol/window.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  CursorPastEndError,
  LogNotDenseError,
  fitOpeningToBytes,
  pageWindow,
  upstreamWindow,
} from '../../src/protocol/window.ts'
import { DEFAULT_PAGE_MESSAGES } from '../../src/protocol/rpc.ts'
import { DEFAULT_FOLLOW_MESSAGES } from '../../src/wire/mux.ts'
import type { WireEvent } from '../../src/wire/rpc.ts'

test('upstreamWindow: the reference spelling of our one-target window rule', () => {
  // The reference splits the rule into a floor it may stop after and a ceiling it
  // must stop at; ours takes one target and derives the ceiling. Here the two
  // spellings meet.
  assert.deepEqual(upstreamWindow(50), {
    maxMessages: 100,
    turnWindow: { minMessages: 50, minTurns: 1 },
  })
  assert.deepEqual(upstreamWindow(7), {
    maxMessages: 14,
    turnWindow: { minMessages: 7, minTurns: 1 },
  })
})

/** A window event; its wire size is supplied by the fixture's own size table. */
function event(type: string, seq: number): WireEvent {
  return { type, seq, time: 1_700_000_000_000 + seq, data: {} }
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
  // 真机抓到的那一条（2026-10-14）：窗口是整份日志，而日志开头不是 `turn/start`
  // （前 4 条事件属于日志的头部）。旧实现只从「第一个 `turn/start`」开始试 ⇒
  // **永远不会试 start = 0** ⇒ 装得下也会被裁到那个边界上。现场读数：
  // `cursor=209, 205 events (narrowed by 4 events / 0 turns), 1253711 bytes (fixed 542 + events 1253169)`
  // —— 1.25 MB 的帧在 4 MiB 的上界下被裁，客户端首屏因此少 4 条。
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

// ---------------------------------------------------------------------------
// pageWindow：窗口算术本体
// ---------------------------------------------------------------------------

/** 每轮四个事件：`user/message`、`turn/start`、`assistant/message`、`turn/end`。 */
function turnedLog(turns: number): WireEvent[] {
  const events: WireEvent[] = []
  const at = (type: string): void => {
    events.push({ type, seq: events.length, time: 1_700_000_000_000 + events.length, data: {} })
  }
  for (let turn = 0; turn < turns; turn += 1) {
    at('user/message')
    at('turn/start')
    at('assistant/message')
    at('turn/end')
  }
  return events
}

test('pageWindow: a log whose seq is not dense is refused, never silently sliced', () => {
  // 算术把位置当 seq 读，稠密是前置条件。不稠密时切出来的窗口指向错的 seq ——
  // 与其发一个对的形状、错的内容，不如拒绝。
  const sparse = turnedLog(2).map((item, index) => index === 5 ? { ...item, seq: 99 } : item)
  assert.throws(() => pageWindow('s1', sparse, undefined, 2), LogNotDenseError)
})

test('pageWindow: a cursor past the log end is refused, because the bound is knowable', () => {
  // 与 `snapshot` 不同：整条日志在手，末端之后的位置是确定的错，不以空窗口作答。
  const log = turnedLog(2)
  assert.throws(() => pageWindow('s1', log, log.length + 1, 2), CursorPastEndError)
})

test('pageWindow: beforeSeq 0 is an empty window at the start, not a refusal', () => {
  const window = pageWindow('s1', turnedLog(2), 0, 2)
  assert.deepEqual(window, { pageStart: 0, asOfSeq: 0, hasOlder: false, events: [] })
})

test('pageWindow: a target larger than the log yields all of it, with nothing older', () => {
  const log = turnedLog(3)
  const window = pageWindow('s1', log, undefined, 99)
  assert.equal(window.pageStart, 0)
  assert.equal(window.asOfSeq, log.length)
  assert.equal(window.hasOlder, false)
  assert.deepEqual(window.events, log)
})

test('pageWindow: the two carriers ask the host and themselves for the same target', () => {
  // 流 opening 的窗口由宿主按 `upstreamWindow` 的拼法切，`page` 由 `pageWindow` 本地切。
  // 两条路径共用的不是同一段代码，而是**同一个目标**与同一个上限倍数 —— 这两条等式
  // 就是「两条出口给出同一个窗口」这句话在今天的可验证形态。
  assert.equal(DEFAULT_FOLLOW_MESSAGES, DEFAULT_PAGE_MESSAGES)
  assert.equal(DEFAULT_FOLLOW_MESSAGES, 50)
  assert.equal(upstreamWindow(DEFAULT_FOLLOW_MESSAGES).maxMessages, DEFAULT_PAGE_MESSAGES * 2)
})
