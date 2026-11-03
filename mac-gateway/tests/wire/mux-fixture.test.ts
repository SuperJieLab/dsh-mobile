/**
 * 两端共守的 mux 帧样本 —— 这里读的是**同一份文件**，不是各写一份字面量。
 *
 * 手机端那条在 `ios/tests/MuxFrameFixtureTests.swift`。两边各写自己的样本时，
 * 改一端而另一端没跟上，两边的测试都还绿 —— 只有联调或真机才暴露。
 *
 * 两个方向各有一条判据，且都**不是**「自己跟自己比」：
 * - client 段：手机端编出这些字节，网关端必须把它们解成同一组语义；
 * - server 段：网关端编出这些字节（逐字比较，键序与字段名都钉住），手机端必须解得开。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'
import { encodeServerFrame, openRequestOf, parseClientFrame, type MuxServerFrame } from '../../src/wire/mux.ts'

interface ClientSample {
  name: string
  text: string
  type: 'open' | 'cancel'
  streamId: string
  op?: string
  sessionId?: string
}

interface ServerSample {
  name: string
  text: string
  type: 'item' | 'end' | 'error'
  streamId: string
}

interface Fixture {
  client: ClientSample[]
  server: ServerSample[]
}

const fixture: Fixture = JSON.parse(
  readFileSync(new URL('../../../contract/mux-frames.json', import.meta.url), 'utf8'),
) as Fixture

/**
 * 服务端样本对应的那条帧 —— 与 `contract/mux-frames.json` 的 `server` 段一一对应。
 *
 * 手写在这里是**有意的**：判据要问的是「同样的语义编出来还是不是那些字节」，
 * 所以语义必须由这一侧独立给出，不能从文件里读回来再编一遍。
 */
const SERVER_FRAMES: Record<string, MuxServerFrame> = {
  'item-follow-opening': {
    type: 'item',
    streamId: 's-9',
    payload: { sessionId: 's-1', cursor: 3, pageStart: 1, hasOlder: false, events: [] },
  },
  'item-events-waterfall': {
    type: 'item',
    streamId: 'e-1',
    payload: {
      kind: 'waterfall', event: 'permission', eventId: 'ev-1', agentId: 's-1', request: {},
    },
  },
  end: { type: 'end', streamId: 's-9' },
  error: { type: 'error', streamId: 's-9', payload: { code: 'unknown-op', message: 'no such op' } },
}

test('the fixture covers both stream kinds and both server frame kinds', () => {
  // 活性锚：样本少一条时下面的循环会静默少测一格，而「少测一格」在测试报告里
  // 长得跟「全绿」一模一样。
  const ops = new Set(fixture.client.map(sample => sample.op).filter(Boolean))
  assert.deepEqual([...ops].sort(), ['events', 'follow'], '两种开流请求都要有样本')
  const serverTypes = new Set(fixture.server.map(sample => sample.type))
  for (const type of ['item', 'end', 'error']) {
    assert.ok(serverTypes.has(type as ServerSample['type']), `服务端帧缺 ${type} 的样本`)
  }
  for (const sample of fixture.server) {
    assert.ok(sample.name in SERVER_FRAMES, `样本 ${sample.name} 在这一侧没有对应的构造`)
  }
})

test('every client sample is exactly what the gateway parses', () => {
  for (const sample of fixture.client) {
    const frame = parseClientFrame(sample.text)
    assert.ok(frame !== undefined, `${sample.name}: 网关解不出这一帧`)
    assert.equal(frame.type, sample.type, `${sample.name}: 信封的 type`)
    assert.equal(frame.streamId, sample.streamId, `${sample.name}: 编号`)

    if (frame.type !== 'open') continue
    const request = openRequestOf(frame.payload)
    assert.ok(request !== undefined, `${sample.name}: 网关认不出这个 open 载荷`)
    assert.equal(request.kind, sample.op, `${sample.name}: 开的是哪种流`)
    if (sample.op === 'follow') {
      assert.equal(sample.sessionId !== undefined, true, `${sample.name}: follow 样本必须带会话名`)
      assert.equal(
        (request as { sessionId?: string }).sessionId,
        sample.sessionId,
        `${sample.name}: 会话名`,
      )
    }
  }
})

test('every server sample is exactly the bytes the gateway emits', () => {
  for (const sample of fixture.server) {
    const frame = SERVER_FRAMES[sample.name]
    assert.ok(frame !== undefined, `${sample.name}: 没有对应的构造`)
    // 逐字比较：字段名、键序、类型名任何一处改了都会红 —— 那正是手机端要解的东西。
    assert.equal(encodeServerFrame(frame), sample.text, `${sample.name}: 网关编出的字节与样本不一致`)
  }
})
