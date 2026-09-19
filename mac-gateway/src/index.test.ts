/**
 * Assembly smoke test.
 *
 * The wiring layer has no pure logic, which is exactly why it went untested —
 * and a mis-anchored edit once shipped a module that evaluated fine and died on
 * the first request. These tests apply the plugin to a minimal fake context and
 * hit a real loopback port with real HTTP, so "the module evaluated" and "the
 * wiring works" are separate claims, each with a failing state of its own.
 *
 * The fake context deliberately provides no services: `apply` must still bring
 * the listener up (inject is the host's concern), and a protocol message must
 * come back as an envelope — `internal-error` here, since nothing is behind the
 * port — rather than a crash. That is the "the process must not crash" promise,
 * checked at the wiring layer.
 *
 * Run: node --test src/index.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { apply } from './index.ts'

/** Random high port: two tests must not race each other or anything real. */
function freshPort(base: number): number {
  return base + Math.floor(Math.random() * 1_500)
}

/** Install the plugin on a context that runs effects immediately. Returns its teardown. */
function install(host: string, port: number): () => void {
  let cleanup: (() => void) | undefined
  apply({ effect: (fn: () => () => void) => { cleanup = fn() } } as never, { host, port })
  return () => cleanup?.()
}

/** Retry the request until the listener is up; give up after two seconds. */
async function untilUp(port: number, request: () => Promise<Response>): Promise<Response> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      return await request()
    } catch {
      await new Promise(resolve => setTimeout(resolve, 50))
    }
  }
  assert.fail('the listener never came up')
}

test('the assembled plugin answers a real request on a real port', async () => {
  const port = freshPort(38_100)
  const teardown = install('127.0.0.1', port)

  try {
    const response = await untilUp(port, () => fetch(`http://127.0.0.1:${port}/`))
    assert.equal(response.status, 200)
    assert.match(await response.text(), /mac-gateway alive/)
  } finally {
    teardown()
  }
})

test('a protocol message is answered with an envelope even when nothing is behind the port', async () => {
  const port = freshPort(39_600)
  const teardown = install('127.0.0.1', port)

  try {
    const response = await untilUp(port, () => fetch(`http://127.0.0.1:${port}/rpc`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ v: 2, op: 'list-sessions' }),
    }))

    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean; error?: { code: string } }
    // The fake context has no services, so the read fails — and must fail as a
    // readable refusal, never as a dead connection.
    assert.equal(body.ok, false)
    assert.equal(body.error?.code, 'internal-error')
  } finally {
    teardown()
  }
})
