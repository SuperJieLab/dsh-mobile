/**
 * The model contract (M7): the one-元 ops for session-level model selection —
 * docs/dev/plans/M7-model-selection.md §四. `model-catalog` is a read op, so a
 * missing port refuses like an unwired write channel does (unreachable in
 * production, where the assembly always wires it).
 *
 * The port is the contract's only dependency; a fake keeps the tests free of
 * runtime and network. Upstream's normalized shapes are forwarded verbatim —
 * validation and normalization live behind the controller's door (决定 3), the
 * contract only relays what that door answered.
 */

/** One normalized model selection, upstream's own vocabulary (决定 3). */
export interface ModelSelection {
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * The Host's model catalog (决定 6): provider-grouped models, the deployment
 * default, and per-provider failures isolated upstream. `routableProviders` is
 * stripped by the adapter — the client has no use for it (§四 契约段).
 */
export interface ModelCatalog {
  /** The deployment default, when the deployment has one. */
  default?: ModelSelection
  /** Provider groups with at least one model. */
  groups: readonly ModelGroup[]
  /** Providers that failed to enumerate, one entry each, never the whole catalog. */
  failures: readonly ModelFailure[]
}

export interface ModelGroup {
  id: string
  name: string
  models: readonly { id: string; name: string }[]
}

export interface ModelFailure {
  id: string
  name: string
  message: string
}

/** The outcome of one select: the normalized choice, or upstream's refusal. */
export type ModelSelectOutcome =
  | { ok: true; selected: ModelSelection }
  | { ok: false; code: 'unknown-session' | 'session/model-unavailable'; message: string }

/** The data source the model ops are written against — the contract's only dependency. */
export interface ModelPort {
  /** The current Host-generation catalog. Failures throw (`internal-error`). */
  catalog(): Promise<ModelCatalog>
  /** Install one session-local selection. Upstream's refusal comes back as a result. */
  select(request: ModelSelectMessage): Promise<ModelSelectOutcome>
}

/** A validated `model-select` message (决定 3's request shape). */
export interface ModelSelectMessage {
  sessionId: string
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * Parse and validate one `model-select` payload, or `undefined` when it cannot
 * be a selection at all. Strict on purpose — the write-path rule (protocol.md
 * §六 `invalid-request`): a malformed selection silently executed would point
 * the next turn at a model nobody chose. `sessionId` is *not* validated here —
 * the read paths already map a malformed id to `unknown-session`, and the write
 * path keeps that convention (contract/write-channel.ts 同款).
 */
export function modelSelectRequestOf(message: Record<string, unknown>): ModelSelectMessage | undefined {
  const sessionId = nonEmptyString(message.sessionId)
  const provider = nonEmptyString(message.provider)
  const model = nonEmptyString(message.model)
  // Present-but-empty mirrors upstream's own schema (`z.string().min(1)`):
  // refused here, never silently read as absent — a write payload is not
  // normalized into a different request than the client sent.
  const reasoningEffort = message.reasoningEffort === undefined ? undefined : nonEmptyString(message.reasoningEffort)
  if (sessionId === undefined || provider === undefined || model === undefined) return undefined
  if (message.reasoningEffort !== undefined && reasoningEffort === undefined) return undefined
  return {
    sessionId,
    provider,
    model,
    ...reasoningEffort === undefined ? {} : { reasoningEffort },
  }
}

/** A non-empty string, or nothing. */
function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}
