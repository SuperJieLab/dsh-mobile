/**
 * The model adapter (M7): the only module that knows the session controller
 * serves model selection. It implements the contract's `ModelPort` over the
 * controller's **declared** face — `selectModel` / `modelCatalog` are public
 * Remote methods (`dsh-api-session-controller/lib/types/index.js:137-138`), so
 * unlike the M5 relay this needs no private-face escape hatch; the drift risk
 * is the parameter *lists*, which the G2 checks below watch (实施期修正 15 的
 * 同族防线：形参名变了要出声，绝不静默按位置喂垃圾).
 *
 * Upstream owns validation and normalization (决定 3): whatever its door
 * answers — the normalized `selected`, or a typed refusal — is relayed, never
 * re-derived here. A second copy of "which model is legal" is how two truths
 * are born.
 */

import { isRemoteError, isNotFound } from '../contract/errors.ts'
import type { ModelCatalog, ModelPort, ModelSelection, ModelSelectMessage, ModelSelectOutcome } from '../contract/model-selection.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.model)

/**
 * The part of the session controller this adapter calls. The signatures are the
 * runtime's, verbatim — a fake that differs from the real face lets a drift
 * pass every test (the lesson of 实施期修正 15/16).
 */
export interface ModelControllerLike {
  selectModel(request: {
    sessionId: string
    provider: string
    model: string
    reasoningEffort?: string
  }): Promise<{ selected: ModelSelection }>
  modelCatalog(): Promise<Record<string, unknown>>
}

/** Build the contract's model port over the controller's declared face. */
export function modelPortOver(controller: ModelControllerLike): ModelPort {
  // Assembly-time signature checks (G2): the calls below pass the request
  // object positionally, which is exact as long as the lists look like the
  // runtime's. A change fires here — at startup, not on the first tap.
  if (!parameterListIs(controller.selectModel, ['request'])) {
    warnSignature('selectModel', controller.selectModel)
  }
  if (!parameterListIs(controller.modelCatalog, [])) {
    warnSignature('modelCatalog', controller.modelCatalog)
  }

  return {
    async catalog(): Promise<ModelCatalog> {
      const raw = (await controller.modelCatalog()) as {
        default?: unknown
        groups?: unknown
        failures?: unknown
      }
      return {
        ...raw.default === undefined || raw.default === null ? {} : { default: raw.default as ModelCatalog['default'] },
        groups: (raw.groups ?? []) as ModelCatalog['groups'],
        failures: (raw.failures ?? []) as ModelCatalog['failures'],
      }
    },

    async select(request: ModelSelectMessage): Promise<ModelSelectOutcome> {
      try {
        const answer = (await controller.selectModel({ ...request })) as { selected: ModelSelection }
        return { ok: true, selected: { ...answer.selected } }
      } catch (error) {
        if (isNotFound(error)) {
          return { ok: false, code: 'unknown-session', message: String((error as { message?: unknown }).message ?? error) }
        }
        if (isRemoteError(error)) {
          return { ok: false, code: error.code as 'session/model-unavailable', message: String((error as { message?: unknown }).message ?? error) }
        }
        throw error
      }
    },
  }
}

/** Whether the callable's parameter list reads as exactly `expected` names. */
function parameterListIs(fn: (...args: never[]) => unknown, expected: readonly string[]): boolean {
  const source = Function.prototype.toString.call(fn)
  const open = source.indexOf('(')
  const close = source.indexOf(')', open + 1)
  if (open === -1 || close === -1) return false // bound or native: unreadable
  const names = source
    .slice(open + 1, close)
    .split(',')
    .map(name => name.trim())
    .filter(name => name.length > 0)
  return names.length === expected.length && expected.every((name, index) => names[index] === name)
}

/** The drift alarm: name what drifted and show the face, so the fix is one read away. */
function warnSignature(member: string, fn: (...args: never[]) => unknown): void {
  log.warn(
    `model adapter: ${member}'s parameter list differs from the runtime signature this build was written against; reads: ${Function.prototype.toString.call(fn).slice(0, 160)}`,
  )
}
