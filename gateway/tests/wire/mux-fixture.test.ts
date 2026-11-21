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
  kind?: string
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
    value: { type: 'snapshot', sessionId: 's-1', cursor: 3, pageStart: 1, hasOlder: false, events: [] },
  },
  'item-events-question': {
    type: 'item',
    streamId: 'e-1',
    // 第二条问题显式 `multiSelect`，第一条省略 —— 缺省是单选，两种都在一条样本里钉住。
    value: {
      type: 'waterfall', event: 'user-questions/request', eventId: 'ev-2', agentId: 's-1',
      request: {
        questions: [
          {
            id: 'q-1', header: '选择方案', question: '用哪一条？',
            options: [{ label: 'A', description: '快' }, { label: 'B' }],
          },
          {
            id: 'q-2', question: '同时改测试吗？',
            options: [{ label: '要' }, { label: '不要' }],
            multiSelect: true,
          },
        ],
      },
    },
  },
  'item-events-emit': {
    type: 'item',
    streamId: 'e-1',
    // `commands/change` 的监听器签名是 `(): void`，转发时参数数组为空。
    value: { type: 'emit', event: 'commands/change', args: [] },
  },
  'item-events-ready': {
    type: 'item',
    streamId: 'e-1',
    // `clientId` 在这里是固定的：这一侧的语义是**手写**的，不走 `openStream` 那条现造 UUID 的路。
    value: { type: 'ready', clientId: 'c-1', host: { home: '/Users/x/proj' } },
  },
  'item-events-waterfall': {
    type: 'item',
    streamId: 'e-1',
    value: {
      type: 'waterfall', event: 'approval/request', eventId: 'ev-1', agentId: 's-1',
      request: { toolName: 'Bash', reason: '需要读写工作区' },
    },
  },
  end: { type: 'end', streamId: 's-9' },
  error: { type: 'error', streamId: 's-9', error: { code: 'unknown-endpoint', message: 'no such endpoint', details: {} } },
}

test('the fixture covers every stream kind and both server frame kinds', () => {
  // 活性锚：样本少一条时下面的循环会静默少测一格，而「少测一格」在测试报告里
  // 长得跟「全绿」一模一样。
  const kinds = new Set(fixture.client.map(sample => sample.kind).filter(Boolean))
  assert.deepEqual([...kinds].sort(), ['control', 'events', 'follow'],
    '三条流的开流请求都要有样本')
  const serverTypes = new Set(fixture.server.map(sample => sample.type))
  for (const type of ['item', 'end', 'error']) {
    assert.ok(serverTypes.has(type as ServerSample['type']), `服务端帧缺 ${type} 的样本`)
  }
  for (const sample of fixture.server) {
    assert.ok(sample.name in SERVER_FRAMES, `样本 ${sample.name} 在这一侧没有对应的构造`)
  }
  // 反方向：构造在、样本没了。只查上面那一个方向时，删掉一条样本这一侧全绿 ——
  // 而「这条货物没人再验」恰恰是最该有人喊的时候。
  for (const name of Object.keys(SERVER_FRAMES)) {
    assert.ok(
      fixture.server.some(sample => sample.name === name),
      `SERVER_FRAMES 的 ${name} 在样本里没有对应 —— 样本被删了这一侧也要红`,
    )
  }
})

test('every client sample is exactly what the gateway parses', () => {
  for (const sample of fixture.client) {
    const frame = parseClientFrame(sample.text)
    assert.ok(frame !== undefined, `${sample.name}: 网关解不出这一帧`)
    assert.equal(frame.type, sample.type, `${sample.name}: 信封的 type`)
    assert.equal(frame.streamId, sample.streamId, `${sample.name}: 编号`)

    if (frame.type !== 'open') continue
    const request = openRequestOf(frame)
    assert.ok(!('error' in request), `${sample.name}: 网关认不出这个 open 端点`)
    assert.equal(request.kind, sample.kind, `${sample.name}: 开的是哪种流`)
    if (sample.kind === 'follow') {
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
