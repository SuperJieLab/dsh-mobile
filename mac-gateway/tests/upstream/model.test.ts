/**
 * The model adapter's tests (M7, dev/plans/M7-model-selection.md §4.1 T2,
 * 判据 G2). The controller fake replicates the **runtime** signatures verbatim
 * (`dsh-api-session-controller/lib/types/index.js` — `selectModel(request)`,
 * `modelCatalog()`); a fake that differs from the real face would let a drift
 * pass every test, which is the lesson of 实施期修正 15/16.
 */

import assert from 'node:assert/strict'
import { test, mock } from 'node:test'

import { modelPortOver, type ModelControllerLike } from '../../src/upstream/model.ts'
import type { ModelSelectMessage } from '../../src/contract/model-selection.ts'

// -- helpers -----------------------------------------------------------------

/** A remote failure the way the runtime throws it (structural, see contract/errors.ts). */
function remoteError(code: string, message: string): Error {
  return Object.assign(new Error(message), { isDSHRemoteError: true, code })
}

/** The runtime's selectModel signature, verbatim: one `request` object, nothing else. */
function fakeController(overrides: Partial<ModelControllerLike> = {}): ModelControllerLike & {
  selections: ModelSelectMessage[]
} {
  const selections: ModelSelectMessage[] = []
  return {
    selections,
    async selectModel(request) {
      selections.push(request)
      // The runtime answers with the *normalized* selection — no sessionId,
      // its own echo of provider/model (commands.js:155-160), never the request.
      return {
        selected: {
          provider: request.provider,
          model: request.model,
          ...(request.reasoningEffort === undefined ? {} : { reasoningEffort: request.reasoningEffort }),
        },
      }
    },
    async modelCatalog() {
      return {
        default: { provider: 'deepseek', model: 'deepseek-chat' },
        routableProviders: ['deepseek'],
        groups: [{ id: 'deepseek', name: 'DeepSeek', models: [{ id: 'deepseek-chat', name: 'DeepSeek Chat' }] }],
        failures: [],
      }
    },
    ...overrides,
  }
}

const REQUEST: ModelSelectMessage = { sessionId: 's', provider: 'deepseek', model: 'deepseek-chat' }

/** Run `body` with console.warn captured; returns what was warned. */
async function captureWarn(body: () => Promise<void>): Promise<string[]> {
  const warnings: string[] = []
  // warn 级经统一 logger 走 stderr（console.error），见 dev/CONVENTIONS.md §2.1。
  const spy = mock.method(console, 'error', (...parts: unknown[]) => { warnings.push(parts.map(String).join(' ')) })
  try {
    await body()
  } finally {
    spy.mock.restore()
  }
  return warnings
}

// -- select: the happy path and upstream's refusals ---------------------------

test('select forwards the request object and hands back the normalized choice', async () => {
  const controller = fakeController()
  const port = modelPortOver(controller)
  const outcome = await port.select(REQUEST)
  assert.deepEqual(outcome, { ok: true, selected: { provider: 'deepseek', model: 'deepseek-chat' } })
  assert.deepEqual(controller.selections, [REQUEST])
})

test('select maps an upstream model-unavailable refusal onto the outcome, not a throw', async () => {
  const port = modelPortOver({
    ...fakeController(),
    async selectModel() {
      throw remoteError('session/model-unavailable', 'no adapter serves provider "x"')
    },
  })
  assert.deepEqual(
    await port.select(REQUEST),
    { ok: false, code: 'session/model-unavailable', message: 'no adapter serves provider "x"' },
  )
})

test('select folds the session-not-found family onto unknown-session (M5 convention)', async () => {
  const port = modelPortOver({
    ...fakeController(),
    async selectModel() {
      throw remoteError('session/not-found', 'no session "s"')
    },
  })
  assert.equal(await port.select(REQUEST).then(o => (o.ok ? 'no' : o.code)), 'unknown-session')
})

test('select rethrows non-remote failures — handle turns them into internal-error', async () => {
  const port = modelPortOver({
    ...fakeController(),
    async selectModel() {
      throw new Error('registry exploded')
    },
  })
  await assert.rejects(port.select(REQUEST), /registry exploded/)
})

// -- G2: the by-name discipline (实施期修正 15 的同族防线) ----------------------

test('G2: a drifted selectModel parameter list warns at assembly time instead of feeding garbage', async () => {
  // The mutation: upstream renamed `request` (or grew the list). The port must
  // still build — the warning is the mechanism, silence is the failure.
  const drifted = {
    ...fakeController(),
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    async selectModel(session: unknown, _request: unknown) {
      return { selected: { provider: 'deepseek', model: 'deepseek-chat' } }
    },
  }
  const warnings = await captureWarn(() => modelPortOver(drifted).select(REQUEST).then(() => {}))
  assert.equal(warnings.length, 1, warnings.join('\n'))
  assert.match(warnings[0]!, /selectModel/)
})

test('G2: an unreadable parameter list (bound/native) warns too', async () => {
  const controller = fakeController()
  const bound = {
    ...controller,
    selectModel: controller.selectModel.bind(null),
  }
  const warnings = await captureWarn(() => modelPortOver(bound).select(REQUEST).then(() => {}))
  assert.equal(warnings.length, 1, warnings.join('\n'))
})

test('G2: modelCatalog growing a parameter warns as well', async () => {
  const grown = {
    ...fakeController(),
    async modelCatalog(_generation: unknown) {
      return {}
    },
  }
  const warnings = await captureWarn(() => modelPortOver(grown).catalog().then(() => {}))
  assert.equal(warnings.length, 1, warnings.join('\n'))
})

// -- catalog: forward verbatim minus client-useless fields ---------------------

test('catalog strips routableProviders and keeps default, groups, failures', async () => {
  const port = modelPortOver(fakeController())
  const catalog = await port.catalog()
  assert.deepEqual(catalog, {
    default: { provider: 'deepseek', model: 'deepseek-chat' },
    groups: [{ id: 'deepseek', name: 'DeepSeek', models: [{ id: 'deepseek-chat', name: 'DeepSeek Chat' }] }],
    failures: [],
  })
})

test('catalog with no deployment default omits the field (决定 7: the client falls back)', async () => {
  const port = modelPortOver({
    ...fakeController(),
    async modelCatalog() {
      return { routableProviders: [], groups: [], failures: [] }
    },
  })
  const catalog = await port.catalog()
  assert.equal('default' in catalog, false)
})
